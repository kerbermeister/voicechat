"""Strict stream command boundary, independent of HTTP/authentication adapters."""
import base64
import binascii
import json
from stream_sessions import StreamError, StreamLimits


def parse_command(raw, limits=None):
    limits = limits or StreamLimits()
    if not isinstance(raw, bytes) or not 0 < len(raw) <= 32768:
        raise StreamError('invalid_request')

    def unique(pairs):
        body = {}
        for key, value in pairs:
            if key in body:
                raise StreamError('invalid_request')
            body[key] = value
        return body

    try:
        body = json.loads(raw.decode('utf-8'), object_pairs_hook=unique,
                          parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except (ValueError, UnicodeError, RecursionError):
        raise StreamError('invalid_request') from None
    if not isinstance(body, dict) or type(body.get('protocol_version')) is not int or body['protocol_version'] != 1:
        raise StreamError('invalid_request')
    operation = body.get('operation')
    fields = {
        'start': {'request_id', 'title', 'description', 'audience', 'comments', 'duration'},
        'heartbeat': {'stream_id', 'ready'},
        'info': {'stream_id'}, 'join': {'stream_id'}, 'leave': {'stream_id'},
        'pause': {'stream_id', 'revision'}, 'resume': {'stream_id', 'revision'},
        'stop': {'stream_id', 'revision'},
        'history': {'stream_id', 'after', 'head', 'limit'},
        'comment': {'stream_id', 'message_id', 'ciphertext'},
        'discover': set(),
        'grant': {'stream_id', 'epoch'},
        'key_roster': {'stream_id'},
        'key_get': {'stream_id'},
        'key_put': {'stream_id', 'epoch', 'user', 'device', 'part', 'parts', 'envelope'},
    }
    if not isinstance(operation, str) or operation not in fields:
        raise StreamError('invalid_request')
    if set(body) != fields[operation] | {'operation', 'protocol_version'}:
        raise StreamError('invalid_request')
    for key in ('stream_id', 'request_id', 'message_id'):
        if key in body and (not isinstance(body[key], str) or not 1 <= len(body[key]) <= 128):
            raise StreamError('invalid_request')
    if 'revision' in body and (type(body['revision']) is not int or not 1 <= body['revision'] <= 9007199254740991):
        raise StreamError('invalid_request')
    if operation == 'comment':
        value = body['ciphertext']
        if not isinstance(value, str) or len(value) > ((limits.message_bytes + 2) // 3) * 4:
            raise StreamError('invalid_message')
        try:
            ciphertext = base64.b64decode(value, validate=True)
        except (ValueError, binascii.Error):
            raise StreamError('invalid_message') from None
        if not 0 < len(ciphertext) <= limits.message_bytes or base64.b64encode(ciphertext).decode() != value:
            raise StreamError('invalid_message')
        body['ciphertext'] = ciphertext
    return body


def dispatch(core, actor, raw):
    """actor comes from a trusted adapter, never from the body.

    No media grant operation exists here: integrating the core must first prove
    key delivery, SFU cleanup/revocation and device authorisation end to end.
    """
    command = parse_command(raw, core.limits)
    operation = command.pop('operation')
    command.pop('protocol_version')
    if operation == 'start':
        return core.start(actor, **command)
    if operation == 'discover':
        return {'streams': core.discover(actor)}
    identifier = command.pop('stream_id')
    if operation in ('pause', 'resume', 'stop'):
        return core.transition(identifier, actor, operation, command['revision'])
    if operation == 'heartbeat':
        return core.heartbeat(identifier, actor, command['ready'])
    if operation == 'comment':
        return {'sequence': core.send(identifier, actor, command['message_id'], command['ciphertext'])}
    if operation == 'history':
        result = core.history(identifier, actor, **command)
        for message in result['messages']:
            message['ciphertext'] = base64.b64encode(message['ciphertext']).decode()
        return result
    if operation in ('grant', 'key_get', 'key_put', 'key_roster'):
        raise StreamError('stream_media_unavailable', 503)
    if operation == 'leave':
        core.leave(identifier, actor)
        return {'left': True}
    if operation == 'join':
        return core.join(identifier, actor)
    return core.info(identifier, actor)
