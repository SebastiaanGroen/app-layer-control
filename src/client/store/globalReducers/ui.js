import { Map, List, fromJS } from 'immutable'
import { isArray, partial, eq } from 'lodash'

import { UPDATE_ASYNC_STATE } from '/store/globalReducers/actions'
import {
	SELECT_DEVICE,
	UPDATE_APPLICATION_ACTIVITY,
	UPDATE_DEVICE_ACTIVITY,
	SET_ASYNC_STATE,
	APPLY_FILTER,
	APPLY_SORT,
	APPLY_INVERT,
} from '/store/constants'

export function applyFilter (query) {
	return {
		type:    APPLY_FILTER,
		payload: query,
		meta:    {
			debounce: {
				time: 250,
			},
		},
	}
}

export function toggleInvert (toggle) {
	return {
		type:    APPLY_INVERT,
		payload: toggle,
		meta:    {
			debounce: {
				time: 50,
			},
		},
	}
}

export function applySort ({ field, ascending }) {
	return {
		type:    APPLY_SORT,
		payload: {
			field,
			ascending,
		},
		meta: {
			debounce: {
				time: 50,
			},
		},
	}
}

export function setAsyncState (name, status) {
	if (!isArray(name)) {
		name = [name]
	}

	return {
		type:    SET_ASYNC_STATE,
		payload: [name, status],
	}
}

export function updateAsyncState (name, status) {
	return {
		type:    UPDATE_ASYNC_STATE,
		payload: [name, status],
	}
}

export function updateDeviceActivity (name, target, status) {
	return {
		type:    UPDATE_DEVICE_ACTIVITY,
		payload: {
			name,
			status,
			target,
		},
	}
}

export function updateApplicationActivity ({
	name,
	deviceId,
	status,
	application,
}) {
	return {
		type:    UPDATE_APPLICATION_ACTIVITY,
		payload: status,
		meta:    {
			application,
			name,
			deviceId,
		},
	}
}

const actionHandlers = {
	[SELECT_DEVICE] (state, { payload }) {
		return state.set('selectedDevice', payload)
	},
	[SET_ASYNC_STATE] (state, { payload }) {
		const [key, status] = payload
		const keyPath       = ['actions', ...key]

		if (state.hasIn(keyPath) && state.getIn(keyPath) === status) {
			console.warn(
				`Potentially unwanted behaviour: ${keyPath.join(
					'.'
				)} is being set to same value '${status}'`
			)
		}

		return state.setIn(keyPath, status)
	},
	[UPDATE_ASYNC_STATE] (state, { payload }) {
		const [name, status] = payload
		return state.set(name, status)
	},
	[UPDATE_DEVICE_ACTIVITY] (state, { payload }) {
		const { name, status } = payload
		const target           = isArray(payload.target) ? payload.target : [payload.target]
		const currentStatuses  = state.get(name, List())

		if (status) {
			return state.set(name, currentStatuses.concat(target))
		} else {
			return state.set(
				name,
				currentStatuses.filterNot(device => target.includes(device))
			)
		}
	},
	[UPDATE_APPLICATION_ACTIVITY] (state, { payload, meta }) {
		const { name, application, deviceId } = meta
		const currentStatuses                 = state.getIn([name, deviceId], List())

		if (payload) {
			return state.setIn([name, deviceId], currentStatuses.push(application))
		} else {
			return state.setIn(
				[name, deviceId],
				currentStatuses.filterNot(partial(eq, application))
			)
		}
	},
	[APPLY_FILTER] (state, { payload }) {
		return state.set('filter', payload)
	},
	[APPLY_SORT] (state, { payload }) {
		return state.set('sort', Map(payload))
	},
	[APPLY_INVERT] (state, { payload }) {
		return state.set('invert', payload)
	},
}

const initialState = fromJS({
	sort: {
		field:     'deviceId',
		ascending: true,
	},
})
export default function uiReducer (state = initialState, action) {
	if (actionHandlers[action.type]) {
		return actionHandlers[action.type](state, action)
	} else {
		return state
	}
}
