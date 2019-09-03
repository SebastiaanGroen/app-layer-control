{ fromJS }          = require "immutable"
createTopicListener = require "../helpers/createTopicListener"

module.exports =
	observable: (socket) ->
		createTopicListener socket, "devices/+id/status"
			.map ({ match, message }) ->
				deviceId = match.id
				status   = message

				fromJS
					deviceId: deviceId
					data:     status: status

	topic: "devices/+/status"
