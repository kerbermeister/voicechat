import 'package:matrix/matrix.dart';

const personalRoomType = 'dev.voicechat.personal';
bool isPersonalRoom(Room room) =>
    room.getState(EventTypes.RoomCreate)?.content['type'] == personalRoomType;
