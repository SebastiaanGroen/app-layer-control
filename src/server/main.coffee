RPC                        = require "mqtt-json-rpc"
WebSocket                  = require "ws"
bodyParser                 = require "body-parser"
compression                = require "compression"
config                     = require "config"
cors                       = require "cors"
express                    = require "express"
http                       = require "http"
morgan                     = require "morgan"
mqtt                       = require "async-mqtt"
{ Map }                    = require "immutable"
{ isEmpty, negate, every } = require "lodash"
{ Subject }                = require "rxjs"

{
	DevicesLogs
	DevicesNsState
	DevicesState
	DevicesStatus
	DeviceGroups
	DockerRegistry
}                              = require "./sources"
Database                       = require "./db/Database"
Store                          = require "./Store"
bundle                         = require "./bundle"
populateMqttWithDeviceGroups   = require "./helpers/populateMqttWithDeviceGroups"
populateMqttWithGroups         = require "./helpers/populateMqttWithGroups"
runUpdates                     = require "./updates"
Watcher                        = require "./db/Watcher"
Broadcaster                    = require "./Broadcaster"
{ installPlugins, runPlugins } = require "./plugins"
log = (require "./lib/Logger") "main"

# Server initialization
app     = express()
server  = http.createServer app
port    = process.env.PORT or config.server.port
ws      = new WebSocket.Server server: server
db      = new Database
store   = new Store db

rpc             = null
deviceStates    = Map()
getDeviceStates = -> deviceStates

log.info "NPM authentication enabled: #{if every config.server.npm then 'yes' else 'no'}"
log.warn "Not publishing messages to MQTT: read only" if config.mqtt.readOnly

app.use cors()
app.use compression()
app.use bodyParser.json strict: true

unless process.env.NODE_ENV is "production"
	# HTTP request logger
	app.use morgan "dev",
		skip: (req) ->
			url   = req.baseUrl
			url or= req.originalUrl

			not url.startsWith "/api"

app.use "/api",         require "./api"
app.use "/api/devices", (require "./api/devices") getDeviceStates

# required to support await operations
do ->
	await bundle app
	await db.connect()
	await runUpdates db: db, store: store

	await installPlugins config.plugins

	await store.ensureDefaultDeviceSources()

	socket         = mqtt.connect config.mqtt
	rpc            = new RPC socket, timeout: config.mqtt.responseTimeout
	broadcaster    = new Broadcaster ws
	watcher        = new Watcher
		db:    db
		store: store
		mqtt:  socket

	onConnect = ->
		log.info "Connected to MQTT Broker at #{config.mqtt.host}:#{config.mqtt.port}"

		await populateMqttWithGroups db, socket
		await populateMqttWithDeviceGroups db, socket

		[
			configurations
			registryImages
			groups
		] = await Promise.all [
			store.getConfigurations()
			store.getRegistryImages()
			store.getGroups()
		]

		store.set "configurations", configurations
		store.set "registry",       registryImages
		store.set "groups",         groups

		log.info "Cache succesfully populated with configurations, registry images and groups"

		devicesLogs$    = DevicesLogs.observable    socket
		devicesNsState$ = DevicesNsState.observable socket
		devicesState$   = DevicesState.observable   socket
		devicesStatus$  = DevicesStatus.observable  socket
		deviceGroups$   = DeviceGroups.observable   socket
		registry$       = DockerRegistry            config.versioning, db
		source$         = new Subject
		# cacheUpdate$    = cacheUpdate               store

		# device logs
		devicesLogs$.subscribe (message) ->
			broadcaster.broadcast "deviceLogs", message

		# state updates
		devicesState$
			.bufferTime config.batchState.defaultInterval
			.filter negate isEmpty
			.subscribe (updates) ->
				deviceStates = updates.reduce (devices, update) ->
					deviceId = update.get "deviceId"
					data     = update.get "data"
					newState = data.merge Map
						lastSeenTimestamp: Date.now()

					# * App Layer Agent sends out 'groups' as part of the state
					# * however, this attribute ought to be set by App Layer Control instead
					keys     = ["groups", "status"]
					newState = (newState.remove key) for key in keys

					devices.mergeIn [deviceId], newState
				, deviceStates

				broadcaster.broadcast "devicesState", deviceStates

		# specific state updates
		# these updates are broadcasted more frequently
		devicesNsState$
			.merge deviceGroups$
			.bufferTime config.batchState.nsStateInterval
			.filter negate isEmpty
			.subscribe (updates) ->
				deviceStates = updates.reduce (devices, update) ->
					key      = update.get "key"
					deviceId = update.get "deviceId"

					devices
						.setIn [deviceId, key], update.get "value"
						.setIn [deviceId, "lastSeenTimestamp"], Date.now()
				, deviceStates

				broadcaster.broadcast "devicesState", deviceStates

		# first time online devices
		devicesStatus$
			.bufferTime config.batchState.nsStateInterval
			.filter negate isEmpty
			.flatMap (updates) ->
				store.ensureDefaultGroups updates.map (update) ->
					update.get "deviceId"
			.subscribe (updates) ->
				{ insertedCount } = updates
				return unless insertedCount

				log.info "Inserted default groups for #{insertedCount} device(s)"

		# status updates
		devicesStatus$
			.bufferTime config.batchState.defaultInterval
			.filter negate isEmpty
			.subscribe (updates) ->
				deviceStates = updates.reduce (devices, update) ->
					deviceId  = update.get "deviceId"
					status    = update.get "status"

					devices
						.setIn [deviceId, "connected"], status is "online"
						.setIn [deviceId, "status"],    status
				, deviceStates

				broadcaster.broadcast "devicesState", deviceStates

		# docker registry
		registry$.subscribe (images) ->
			await store.storeRegistryImages images
			broadcaster.broadcastRegistry()

		# plugin sources
		source$
			.filter ({ _internal }) ->
				not _internal
			.bufferTime config.batchState.defaultInterval
			.filter negate isEmpty
			.subscribe (updates) ->
				deviceStates = updates
					.filter ({ deviceId, data }) ->
						return log.warn "No device ID found in state payload. Ignoring update ..." unless deviceId?
						return log.warn "No data found in state payload. Ignoring update ..."      unless data?
						true
					.reduce (devices, { deviceId, data }) ->
						devices.mergeIn [deviceId], data
					, deviceStates

				broadcaster.broadcast "devicesState", deviceStates

		[
			["devicesNsState", devicesNsState$]
			["devicesState",   devicesState$]
			["devicesStatus",  devicesStatus$]
		].forEach ([name, observable$]) ->
			observable$
				.map (data) ->
					name:      name
					data:      data
					_internal: true
				.subscribe source$

		# plugins
		runPlugins config.plugins, source$

		socket.subscribe [
			DevicesState.topic
			DevicesLogs.topic
			DevicesNsState.topic
			DevicesStatus.topic
			DeviceGroups.topic
		], (error, granted) ->
			throw new Error "Error subscribing topics: #{error.message}" if error

			log.info "Subscribed to MQTT"
			log.info "Topics: #{granted.map(({ topic }) -> topic).join ", "}"

	onError = (error) ->
		log.error error.message

	onClose = ->
		log.warn "Connection to the MQTT broker closed"

	socket
		.on "connect", onConnect
		.on "error",   onError
		.on "close",   onClose

	# start watching on database changes
	watcher.watch()

	# provide tools for routes
	app.locals.rpc         = rpc
	app.locals.mqtt        = socket
	app.locals.db          = db
	app.locals.broadcaster = broadcaster

	server.listen port, ->
		log.info "Server listening on :#{@address().port}"

# inspect state of a device through CLI
process
	.stdin
	.on "data", (data) ->
		return if process.env.NODE_ENV is "production"

		input = data.toString().trim()
		return unless input.startsWith ".inspect"

		deviceId = input
			.split " "
			.slice 1
			.join ""
		return console.warn "device '#{deviceId}' not found" unless deviceStates.get deviceId

		file  = require("path").join ".local", deviceId
		state = deviceStates
			.get deviceId
			.toJS()

		require("fs").writeFileSync file, JSON.stringify state, null, 4
		console.log "state stored in #{file}"
