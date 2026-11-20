// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'dto.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ConnectEventDto {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ConnectEventDto);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'ConnectEventDto()';
}


}

/// @nodoc
class $ConnectEventDtoCopyWith<$Res>  {
$ConnectEventDtoCopyWith(ConnectEventDto _, $Res Function(ConnectEventDto) __);
}


/// Adds pattern-matching-related methods to [ConnectEventDto].
extension ConnectEventDtoPatterns on ConnectEventDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( ConnectEventDto_DevicesChanged value)?  devicesChanged,TResult Function( ConnectEventDto_PairingCode value)?  pairingCode,TResult Function( ConnectEventDto_PairingFinished value)?  pairingFinished,TResult Function( ConnectEventDto_RemoteState value)?  remoteState,TResult Function( ConnectEventDto_SessionClosed value)?  sessionClosed,TResult Function( ConnectEventDto_ControllersChanged value)?  controllersChanged,required TResult orElse(),}){
final _that = this;
switch (_that) {
case ConnectEventDto_DevicesChanged() when devicesChanged != null:
return devicesChanged(_that);case ConnectEventDto_PairingCode() when pairingCode != null:
return pairingCode(_that);case ConnectEventDto_PairingFinished() when pairingFinished != null:
return pairingFinished(_that);case ConnectEventDto_RemoteState() when remoteState != null:
return remoteState(_that);case ConnectEventDto_SessionClosed() when sessionClosed != null:
return sessionClosed(_that);case ConnectEventDto_ControllersChanged() when controllersChanged != null:
return controllersChanged(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( ConnectEventDto_DevicesChanged value)  devicesChanged,required TResult Function( ConnectEventDto_PairingCode value)  pairingCode,required TResult Function( ConnectEventDto_PairingFinished value)  pairingFinished,required TResult Function( ConnectEventDto_RemoteState value)  remoteState,required TResult Function( ConnectEventDto_SessionClosed value)  sessionClosed,required TResult Function( ConnectEventDto_ControllersChanged value)  controllersChanged,}){
final _that = this;
switch (_that) {
case ConnectEventDto_DevicesChanged():
return devicesChanged(_that);case ConnectEventDto_PairingCode():
return pairingCode(_that);case ConnectEventDto_PairingFinished():
return pairingFinished(_that);case ConnectEventDto_RemoteState():
return remoteState(_that);case ConnectEventDto_SessionClosed():
return sessionClosed(_that);case ConnectEventDto_ControllersChanged():
return controllersChanged(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( ConnectEventDto_DevicesChanged value)?  devicesChanged,TResult? Function( ConnectEventDto_PairingCode value)?  pairingCode,TResult? Function( ConnectEventDto_PairingFinished value)?  pairingFinished,TResult? Function( ConnectEventDto_RemoteState value)?  remoteState,TResult? Function( ConnectEventDto_SessionClosed value)?  sessionClosed,TResult? Function( ConnectEventDto_ControllersChanged value)?  controllersChanged,}){
final _that = this;
switch (_that) {
case ConnectEventDto_DevicesChanged() when devicesChanged != null:
return devicesChanged(_that);case ConnectEventDto_PairingCode() when pairingCode != null:
return pairingCode(_that);case ConnectEventDto_PairingFinished() when pairingFinished != null:
return pairingFinished(_that);case ConnectEventDto_RemoteState() when remoteState != null:
return remoteState(_that);case ConnectEventDto_SessionClosed() when sessionClosed != null:
return sessionClosed(_that);case ConnectEventDto_ControllersChanged() when controllersChanged != null:
return controllersChanged(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( List<ConnectDeviceDto> devices)?  devicesChanged,TResult Function( String peerId,  String peerName,  String code)?  pairingCode,TResult Function( String peerId,  String peerName,  bool success)?  pairingFinished,TResult Function( String deviceId,  RemoteStateDto state)?  remoteState,TResult Function( String deviceId,  String reason)?  sessionClosed,TResult Function( List<String> names)?  controllersChanged,required TResult orElse(),}) {final _that = this;
switch (_that) {
case ConnectEventDto_DevicesChanged() when devicesChanged != null:
return devicesChanged(_that.devices);case ConnectEventDto_PairingCode() when pairingCode != null:
return pairingCode(_that.peerId,_that.peerName,_that.code);case ConnectEventDto_PairingFinished() when pairingFinished != null:
return pairingFinished(_that.peerId,_that.peerName,_that.success);case ConnectEventDto_RemoteState() when remoteState != null:
return remoteState(_that.deviceId,_that.state);case ConnectEventDto_SessionClosed() when sessionClosed != null:
return sessionClosed(_that.deviceId,_that.reason);case ConnectEventDto_ControllersChanged() when controllersChanged != null:
return controllersChanged(_that.names);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( List<ConnectDeviceDto> devices)  devicesChanged,required TResult Function( String peerId,  String peerName,  String code)  pairingCode,required TResult Function( String peerId,  String peerName,  bool success)  pairingFinished,required TResult Function( String deviceId,  RemoteStateDto state)  remoteState,required TResult Function( String deviceId,  String reason)  sessionClosed,required TResult Function( List<String> names)  controllersChanged,}) {final _that = this;
switch (_that) {
case ConnectEventDto_DevicesChanged():
return devicesChanged(_that.devices);case ConnectEventDto_PairingCode():
return pairingCode(_that.peerId,_that.peerName,_that.code);case ConnectEventDto_PairingFinished():
return pairingFinished(_that.peerId,_that.peerName,_that.success);case ConnectEventDto_RemoteState():
return remoteState(_that.deviceId,_that.state);case ConnectEventDto_SessionClosed():
return sessionClosed(_that.deviceId,_that.reason);case ConnectEventDto_ControllersChanged():
return controllersChanged(_that.names);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( List<ConnectDeviceDto> devices)?  devicesChanged,TResult? Function( String peerId,  String peerName,  String code)?  pairingCode,TResult? Function( String peerId,  String peerName,  bool success)?  pairingFinished,TResult? Function( String deviceId,  RemoteStateDto state)?  remoteState,TResult? Function( String deviceId,  String reason)?  sessionClosed,TResult? Function( List<String> names)?  controllersChanged,}) {final _that = this;
switch (_that) {
case ConnectEventDto_DevicesChanged() when devicesChanged != null:
return devicesChanged(_that.devices);case ConnectEventDto_PairingCode() when pairingCode != null:
return pairingCode(_that.peerId,_that.peerName,_that.code);case ConnectEventDto_PairingFinished() when pairingFinished != null:
return pairingFinished(_that.peerId,_that.peerName,_that.success);case ConnectEventDto_RemoteState() when remoteState != null:
return remoteState(_that.deviceId,_that.state);case ConnectEventDto_SessionClosed() when sessionClosed != null:
return sessionClosed(_that.deviceId,_that.reason);case ConnectEventDto_ControllersChanged() when controllersChanged != null:
return controllersChanged(_that.names);case _:
  return null;

}
}

}

/// @nodoc


class ConnectEventDto_DevicesChanged extends ConnectEventDto {
  const ConnectEventDto_DevicesChanged({required  List<ConnectDeviceDto> devices}): _devices = devices,super._();
  

/// 当前局域网里（含手动添加的）所有设备。
 final  List<ConnectDeviceDto> _devices;
/// 当前局域网里（含手动添加的）所有设备。
 List<ConnectDeviceDto> get devices {
  if (_devices is EqualUnmodifiableListView) return _devices;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_devices);
}


/// Create a copy of ConnectEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ConnectEventDto_DevicesChangedCopyWith<ConnectEventDto_DevicesChanged> get copyWith => _$ConnectEventDto_DevicesChangedCopyWithImpl<ConnectEventDto_DevicesChanged>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ConnectEventDto_DevicesChanged&&const DeepCollectionEquality().equals(other.devices, _devices));
}


@override
int get hashCode {
    return Object.hash(runtimeType,const DeepCollectionEquality().hash(_devices));
}

@override
String toString() {
    return 'ConnectEventDto.devicesChanged(devices: $devices)';
}


}

/// @nodoc
abstract mixin class $ConnectEventDto_DevicesChangedCopyWith<$Res> implements $ConnectEventDtoCopyWith<$Res> {
  factory $ConnectEventDto_DevicesChangedCopyWith(ConnectEventDto_DevicesChanged value, $Res Function(ConnectEventDto_DevicesChanged) _then) = _$ConnectEventDto_DevicesChangedCopyWithImpl;
@useResult
$Res call({
 List<ConnectDeviceDto> devices
});




}
/// @nodoc
class _$ConnectEventDto_DevicesChangedCopyWithImpl<$Res>
    implements $ConnectEventDto_DevicesChangedCopyWith<$Res> {
  _$ConnectEventDto_DevicesChangedCopyWithImpl(this._self, this._then);

  final ConnectEventDto_DevicesChanged _self;
  final $Res Function(ConnectEventDto_DevicesChanged) _then;

/// Create a copy of ConnectEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? devices = null,}) {
  return _then(ConnectEventDto_DevicesChanged(
devices: null == devices ? _self._devices : devices // ignore: cast_nullable_to_non_nullable
as List<ConnectDeviceDto>,
  ));
}


}

/// @nodoc


class ConnectEventDto_PairingCode extends ConnectEventDto {
  const ConnectEventDto_PairingCode({required this.peerId, required this.peerName, required this.code}): super._();
  

/// 请求配对的设备 ID。
 final  String peerId;
/// 请求配对的设备名。
 final  String peerName;
/// 6 位配对码，用户需要把它输进那台设备。
 final  String code;

/// Create a copy of ConnectEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ConnectEventDto_PairingCodeCopyWith<ConnectEventDto_PairingCode> get copyWith => _$ConnectEventDto_PairingCodeCopyWithImpl<ConnectEventDto_PairingCode>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ConnectEventDto_PairingCode&&(identical(other.peerId, peerId) || other.peerId == peerId)&&(identical(other.peerName, peerName) || other.peerName == peerName)&&(identical(other.code, code) || other.code == code));
}


@override
int get hashCode {
    return Object.hash(runtimeType,peerId,peerName,code);
}

@override
String toString() {
    return 'ConnectEventDto.pairingCode(peerId: $peerId, peerName: $peerName, code: $code)';
}


}

/// @nodoc
abstract mixin class $ConnectEventDto_PairingCodeCopyWith<$Res> implements $ConnectEventDtoCopyWith<$Res> {
  factory $ConnectEventDto_PairingCodeCopyWith(ConnectEventDto_PairingCode value, $Res Function(ConnectEventDto_PairingCode) _then) = _$ConnectEventDto_PairingCodeCopyWithImpl;
@useResult
$Res call({
 String peerId, String peerName, String code
});




}
/// @nodoc
class _$ConnectEventDto_PairingCodeCopyWithImpl<$Res>
    implements $ConnectEventDto_PairingCodeCopyWith<$Res> {
  _$ConnectEventDto_PairingCodeCopyWithImpl(this._self, this._then);

  final ConnectEventDto_PairingCode _self;
  final $Res Function(ConnectEventDto_PairingCode) _then;

/// Create a copy of ConnectEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,Object? peerName = null,Object? code = null,}) {
  return _then(ConnectEventDto_PairingCode(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,peerName: null == peerName ? _self.peerName : peerName // ignore: cast_nullable_to_non_nullable
as String,code: null == code ? _self.code : code // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class ConnectEventDto_PairingFinished extends ConnectEventDto {
  const ConnectEventDto_PairingFinished({required this.peerId, required this.peerName, required this.success}): super._();
  

/// 请求配对的设备 ID。
 final  String peerId;
/// 请求配对的设备名。
 final  String peerName;
/// 是否成功。
 final  bool success;

/// Create a copy of ConnectEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ConnectEventDto_PairingFinishedCopyWith<ConnectEventDto_PairingFinished> get copyWith => _$ConnectEventDto_PairingFinishedCopyWithImpl<ConnectEventDto_PairingFinished>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ConnectEventDto_PairingFinished&&(identical(other.peerId, peerId) || other.peerId == peerId)&&(identical(other.peerName, peerName) || other.peerName == peerName)&&(identical(other.success, success) || other.success == success));
}


@override
int get hashCode {
    return Object.hash(runtimeType,peerId,peerName,success);
}

@override
String toString() {
    return 'ConnectEventDto.pairingFinished(peerId: $peerId, peerName: $peerName, success: $success)';
}


}

/// @nodoc
abstract mixin class $ConnectEventDto_PairingFinishedCopyWith<$Res> implements $ConnectEventDtoCopyWith<$Res> {
  factory $ConnectEventDto_PairingFinishedCopyWith(ConnectEventDto_PairingFinished value, $Res Function(ConnectEventDto_PairingFinished) _then) = _$ConnectEventDto_PairingFinishedCopyWithImpl;
@useResult
$Res call({
 String peerId, String peerName, bool success
});




}
/// @nodoc
class _$ConnectEventDto_PairingFinishedCopyWithImpl<$Res>
    implements $ConnectEventDto_PairingFinishedCopyWith<$Res> {
  _$ConnectEventDto_PairingFinishedCopyWithImpl(this._self, this._then);

  final ConnectEventDto_PairingFinished _self;
  final $Res Function(ConnectEventDto_PairingFinished) _then;

/// Create a copy of ConnectEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,Object? peerName = null,Object? success = null,}) {
  return _then(ConnectEventDto_PairingFinished(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,peerName: null == peerName ? _self.peerName : peerName // ignore: cast_nullable_to_non_nullable
as String,success: null == success ? _self.success : success // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class ConnectEventDto_RemoteState extends ConnectEventDto {
  const ConnectEventDto_RemoteState({required this.deviceId, required this.state}): super._();
  

/// 哪台设备。
 final  String deviceId;
/// 它的最新状态。
 final  RemoteStateDto state;

/// Create a copy of ConnectEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ConnectEventDto_RemoteStateCopyWith<ConnectEventDto_RemoteState> get copyWith => _$ConnectEventDto_RemoteStateCopyWithImpl<ConnectEventDto_RemoteState>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ConnectEventDto_RemoteState&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.state, state) || other.state == state));
}


@override
int get hashCode {
    return Object.hash(runtimeType,deviceId,state);
}

@override
String toString() {
    return 'ConnectEventDto.remoteState(deviceId: $deviceId, state: $state)';
}


}

/// @nodoc
abstract mixin class $ConnectEventDto_RemoteStateCopyWith<$Res> implements $ConnectEventDtoCopyWith<$Res> {
  factory $ConnectEventDto_RemoteStateCopyWith(ConnectEventDto_RemoteState value, $Res Function(ConnectEventDto_RemoteState) _then) = _$ConnectEventDto_RemoteStateCopyWithImpl;
@useResult
$Res call({
 String deviceId, RemoteStateDto state
});




}
/// @nodoc
class _$ConnectEventDto_RemoteStateCopyWithImpl<$Res>
    implements $ConnectEventDto_RemoteStateCopyWith<$Res> {
  _$ConnectEventDto_RemoteStateCopyWithImpl(this._self, this._then);

  final ConnectEventDto_RemoteState _self;
  final $Res Function(ConnectEventDto_RemoteState) _then;

/// Create a copy of ConnectEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceId = null,Object? state = null,}) {
  return _then(ConnectEventDto_RemoteState(
deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as RemoteStateDto,
  ));
}


}

/// @nodoc


class ConnectEventDto_SessionClosed extends ConnectEventDto {
  const ConnectEventDto_SessionClosed({required this.deviceId, required this.reason}): super._();
  

/// 哪台设备。
 final  String deviceId;
/// 断开的原因（给日志 / 提示用）。
 final  String reason;

/// Create a copy of ConnectEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ConnectEventDto_SessionClosedCopyWith<ConnectEventDto_SessionClosed> get copyWith => _$ConnectEventDto_SessionClosedCopyWithImpl<ConnectEventDto_SessionClosed>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ConnectEventDto_SessionClosed&&(identical(other.deviceId, deviceId) || other.deviceId == deviceId)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode {
    return Object.hash(runtimeType,deviceId,reason);
}

@override
String toString() {
    return 'ConnectEventDto.sessionClosed(deviceId: $deviceId, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $ConnectEventDto_SessionClosedCopyWith<$Res> implements $ConnectEventDtoCopyWith<$Res> {
  factory $ConnectEventDto_SessionClosedCopyWith(ConnectEventDto_SessionClosed value, $Res Function(ConnectEventDto_SessionClosed) _then) = _$ConnectEventDto_SessionClosedCopyWithImpl;
@useResult
$Res call({
 String deviceId, String reason
});




}
/// @nodoc
class _$ConnectEventDto_SessionClosedCopyWithImpl<$Res>
    implements $ConnectEventDto_SessionClosedCopyWith<$Res> {
  _$ConnectEventDto_SessionClosedCopyWithImpl(this._self, this._then);

  final ConnectEventDto_SessionClosed _self;
  final $Res Function(ConnectEventDto_SessionClosed) _then;

/// Create a copy of ConnectEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deviceId = null,Object? reason = null,}) {
  return _then(ConnectEventDto_SessionClosed(
deviceId: null == deviceId ? _self.deviceId : deviceId // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class ConnectEventDto_ControllersChanged extends ConnectEventDto {
  const ConnectEventDto_ControllersChanged({required  List<String> names}): _names = names,super._();
  

/// 当前连着本机的控制端名字。
 final  List<String> _names;
/// 当前连着本机的控制端名字。
 List<String> get names {
  if (_names is EqualUnmodifiableListView) return _names;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_names);
}


/// Create a copy of ConnectEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ConnectEventDto_ControllersChangedCopyWith<ConnectEventDto_ControllersChanged> get copyWith => _$ConnectEventDto_ControllersChangedCopyWithImpl<ConnectEventDto_ControllersChanged>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ConnectEventDto_ControllersChanged&&const DeepCollectionEquality().equals(other.names, _names));
}


@override
int get hashCode {
    return Object.hash(runtimeType,const DeepCollectionEquality().hash(_names));
}

@override
String toString() {
    return 'ConnectEventDto.controllersChanged(names: $names)';
}


}

/// @nodoc
abstract mixin class $ConnectEventDto_ControllersChangedCopyWith<$Res> implements $ConnectEventDtoCopyWith<$Res> {
  factory $ConnectEventDto_ControllersChangedCopyWith(ConnectEventDto_ControllersChanged value, $Res Function(ConnectEventDto_ControllersChanged) _then) = _$ConnectEventDto_ControllersChangedCopyWithImpl;
@useResult
$Res call({
 List<String> names
});




}
/// @nodoc
class _$ConnectEventDto_ControllersChangedCopyWithImpl<$Res>
    implements $ConnectEventDto_ControllersChangedCopyWith<$Res> {
  _$ConnectEventDto_ControllersChangedCopyWithImpl(this._self, this._then);

  final ConnectEventDto_ControllersChanged _self;
  final $Res Function(ConnectEventDto_ControllersChanged) _then;

/// Create a copy of ConnectEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? names = null,}) {
  return _then(ConnectEventDto_ControllersChanged(
names: null == names ? _self._names : names // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}


}

/// @nodoc
mixin _$ControlActionDto {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ControlActionDto);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'ControlActionDto()';
}


}

/// @nodoc
class $ControlActionDtoCopyWith<$Res>  {
$ControlActionDtoCopyWith(ControlActionDto _, $Res Function(ControlActionDto) __);
}


/// Adds pattern-matching-related methods to [ControlActionDto].
extension ControlActionDtoPatterns on ControlActionDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( ControlActionDto_Play value)?  play,TResult Function( ControlActionDto_Pause value)?  pause,TResult Function( ControlActionDto_Toggle value)?  toggle,TResult Function( ControlActionDto_Next value)?  next,TResult Function( ControlActionDto_Previous value)?  previous,TResult Function( ControlActionDto_Seek value)?  seek,TResult Function( ControlActionDto_Volume value)?  volume,TResult Function( ControlActionDto_Repeat value)?  repeat,TResult Function( ControlActionDto_Shuffle value)?  shuffle,TResult Function( ControlActionDto_PlayIndex value)?  playIndex,required TResult orElse(),}){
final _that = this;
switch (_that) {
case ControlActionDto_Play() when play != null:
return play(_that);case ControlActionDto_Pause() when pause != null:
return pause(_that);case ControlActionDto_Toggle() when toggle != null:
return toggle(_that);case ControlActionDto_Next() when next != null:
return next(_that);case ControlActionDto_Previous() when previous != null:
return previous(_that);case ControlActionDto_Seek() when seek != null:
return seek(_that);case ControlActionDto_Volume() when volume != null:
return volume(_that);case ControlActionDto_Repeat() when repeat != null:
return repeat(_that);case ControlActionDto_Shuffle() when shuffle != null:
return shuffle(_that);case ControlActionDto_PlayIndex() when playIndex != null:
return playIndex(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( ControlActionDto_Play value)  play,required TResult Function( ControlActionDto_Pause value)  pause,required TResult Function( ControlActionDto_Toggle value)  toggle,required TResult Function( ControlActionDto_Next value)  next,required TResult Function( ControlActionDto_Previous value)  previous,required TResult Function( ControlActionDto_Seek value)  seek,required TResult Function( ControlActionDto_Volume value)  volume,required TResult Function( ControlActionDto_Repeat value)  repeat,required TResult Function( ControlActionDto_Shuffle value)  shuffle,required TResult Function( ControlActionDto_PlayIndex value)  playIndex,}){
final _that = this;
switch (_that) {
case ControlActionDto_Play():
return play(_that);case ControlActionDto_Pause():
return pause(_that);case ControlActionDto_Toggle():
return toggle(_that);case ControlActionDto_Next():
return next(_that);case ControlActionDto_Previous():
return previous(_that);case ControlActionDto_Seek():
return seek(_that);case ControlActionDto_Volume():
return volume(_that);case ControlActionDto_Repeat():
return repeat(_that);case ControlActionDto_Shuffle():
return shuffle(_that);case ControlActionDto_PlayIndex():
return playIndex(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( ControlActionDto_Play value)?  play,TResult? Function( ControlActionDto_Pause value)?  pause,TResult? Function( ControlActionDto_Toggle value)?  toggle,TResult? Function( ControlActionDto_Next value)?  next,TResult? Function( ControlActionDto_Previous value)?  previous,TResult? Function( ControlActionDto_Seek value)?  seek,TResult? Function( ControlActionDto_Volume value)?  volume,TResult? Function( ControlActionDto_Repeat value)?  repeat,TResult? Function( ControlActionDto_Shuffle value)?  shuffle,TResult? Function( ControlActionDto_PlayIndex value)?  playIndex,}){
final _that = this;
switch (_that) {
case ControlActionDto_Play() when play != null:
return play(_that);case ControlActionDto_Pause() when pause != null:
return pause(_that);case ControlActionDto_Toggle() when toggle != null:
return toggle(_that);case ControlActionDto_Next() when next != null:
return next(_that);case ControlActionDto_Previous() when previous != null:
return previous(_that);case ControlActionDto_Seek() when seek != null:
return seek(_that);case ControlActionDto_Volume() when volume != null:
return volume(_that);case ControlActionDto_Repeat() when repeat != null:
return repeat(_that);case ControlActionDto_Shuffle() when shuffle != null:
return shuffle(_that);case ControlActionDto_PlayIndex() when playIndex != null:
return playIndex(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  play,TResult Function()?  pause,TResult Function()?  toggle,TResult Function()?  next,TResult Function()?  previous,TResult Function( BigInt positionMs)?  seek,TResult Function( double volume)?  volume,TResult Function( RepeatModeDto mode)?  repeat,TResult Function( ShuffleModeDto mode)?  shuffle,TResult Function( int index)?  playIndex,required TResult orElse(),}) {final _that = this;
switch (_that) {
case ControlActionDto_Play() when play != null:
return play();case ControlActionDto_Pause() when pause != null:
return pause();case ControlActionDto_Toggle() when toggle != null:
return toggle();case ControlActionDto_Next() when next != null:
return next();case ControlActionDto_Previous() when previous != null:
return previous();case ControlActionDto_Seek() when seek != null:
return seek(_that.positionMs);case ControlActionDto_Volume() when volume != null:
return volume(_that.volume);case ControlActionDto_Repeat() when repeat != null:
return repeat(_that.mode);case ControlActionDto_Shuffle() when shuffle != null:
return shuffle(_that.mode);case ControlActionDto_PlayIndex() when playIndex != null:
return playIndex(_that.index);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  play,required TResult Function()  pause,required TResult Function()  toggle,required TResult Function()  next,required TResult Function()  previous,required TResult Function( BigInt positionMs)  seek,required TResult Function( double volume)  volume,required TResult Function( RepeatModeDto mode)  repeat,required TResult Function( ShuffleModeDto mode)  shuffle,required TResult Function( int index)  playIndex,}) {final _that = this;
switch (_that) {
case ControlActionDto_Play():
return play();case ControlActionDto_Pause():
return pause();case ControlActionDto_Toggle():
return toggle();case ControlActionDto_Next():
return next();case ControlActionDto_Previous():
return previous();case ControlActionDto_Seek():
return seek(_that.positionMs);case ControlActionDto_Volume():
return volume(_that.volume);case ControlActionDto_Repeat():
return repeat(_that.mode);case ControlActionDto_Shuffle():
return shuffle(_that.mode);case ControlActionDto_PlayIndex():
return playIndex(_that.index);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  play,TResult? Function()?  pause,TResult? Function()?  toggle,TResult? Function()?  next,TResult? Function()?  previous,TResult? Function( BigInt positionMs)?  seek,TResult? Function( double volume)?  volume,TResult? Function( RepeatModeDto mode)?  repeat,TResult? Function( ShuffleModeDto mode)?  shuffle,TResult? Function( int index)?  playIndex,}) {final _that = this;
switch (_that) {
case ControlActionDto_Play() when play != null:
return play();case ControlActionDto_Pause() when pause != null:
return pause();case ControlActionDto_Toggle() when toggle != null:
return toggle();case ControlActionDto_Next() when next != null:
return next();case ControlActionDto_Previous() when previous != null:
return previous();case ControlActionDto_Seek() when seek != null:
return seek(_that.positionMs);case ControlActionDto_Volume() when volume != null:
return volume(_that.volume);case ControlActionDto_Repeat() when repeat != null:
return repeat(_that.mode);case ControlActionDto_Shuffle() when shuffle != null:
return shuffle(_that.mode);case ControlActionDto_PlayIndex() when playIndex != null:
return playIndex(_that.index);case _:
  return null;

}
}

}

/// @nodoc


class ControlActionDto_Play extends ControlActionDto {
  const ControlActionDto_Play(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ControlActionDto_Play);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'ControlActionDto.play()';
}


}




/// @nodoc


class ControlActionDto_Pause extends ControlActionDto {
  const ControlActionDto_Pause(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ControlActionDto_Pause);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'ControlActionDto.pause()';
}


}




/// @nodoc


class ControlActionDto_Toggle extends ControlActionDto {
  const ControlActionDto_Toggle(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ControlActionDto_Toggle);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'ControlActionDto.toggle()';
}


}




/// @nodoc


class ControlActionDto_Next extends ControlActionDto {
  const ControlActionDto_Next(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ControlActionDto_Next);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'ControlActionDto.next()';
}


}




/// @nodoc


class ControlActionDto_Previous extends ControlActionDto {
  const ControlActionDto_Previous(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ControlActionDto_Previous);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'ControlActionDto.previous()';
}


}




/// @nodoc


class ControlActionDto_Seek extends ControlActionDto {
  const ControlActionDto_Seek({required this.positionMs}): super._();
  

/// 目标位置（毫秒）。
 final  BigInt positionMs;

/// Create a copy of ControlActionDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ControlActionDto_SeekCopyWith<ControlActionDto_Seek> get copyWith => _$ControlActionDto_SeekCopyWithImpl<ControlActionDto_Seek>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ControlActionDto_Seek&&(identical(other.positionMs, positionMs) || other.positionMs == positionMs));
}


@override
int get hashCode {
    return Object.hash(runtimeType,positionMs);
}

@override
String toString() {
    return 'ControlActionDto.seek(positionMs: $positionMs)';
}


}

/// @nodoc
abstract mixin class $ControlActionDto_SeekCopyWith<$Res> implements $ControlActionDtoCopyWith<$Res> {
  factory $ControlActionDto_SeekCopyWith(ControlActionDto_Seek value, $Res Function(ControlActionDto_Seek) _then) = _$ControlActionDto_SeekCopyWithImpl;
@useResult
$Res call({
 BigInt positionMs
});




}
/// @nodoc
class _$ControlActionDto_SeekCopyWithImpl<$Res>
    implements $ControlActionDto_SeekCopyWith<$Res> {
  _$ControlActionDto_SeekCopyWithImpl(this._self, this._then);

  final ControlActionDto_Seek _self;
  final $Res Function(ControlActionDto_Seek) _then;

/// Create a copy of ControlActionDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? positionMs = null,}) {
  return _then(ControlActionDto_Seek(
positionMs: null == positionMs ? _self.positionMs : positionMs // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class ControlActionDto_Volume extends ControlActionDto {
  const ControlActionDto_Volume({required this.volume}): super._();
  

/// 0..=1。
 final  double volume;

/// Create a copy of ControlActionDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ControlActionDto_VolumeCopyWith<ControlActionDto_Volume> get copyWith => _$ControlActionDto_VolumeCopyWithImpl<ControlActionDto_Volume>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ControlActionDto_Volume&&(identical(other.volume, volume) || other.volume == volume));
}


@override
int get hashCode {
    return Object.hash(runtimeType,volume);
}

@override
String toString() {
    return 'ControlActionDto.volume(volume: $volume)';
}


}

/// @nodoc
abstract mixin class $ControlActionDto_VolumeCopyWith<$Res> implements $ControlActionDtoCopyWith<$Res> {
  factory $ControlActionDto_VolumeCopyWith(ControlActionDto_Volume value, $Res Function(ControlActionDto_Volume) _then) = _$ControlActionDto_VolumeCopyWithImpl;
@useResult
$Res call({
 double volume
});




}
/// @nodoc
class _$ControlActionDto_VolumeCopyWithImpl<$Res>
    implements $ControlActionDto_VolumeCopyWith<$Res> {
  _$ControlActionDto_VolumeCopyWithImpl(this._self, this._then);

  final ControlActionDto_Volume _self;
  final $Res Function(ControlActionDto_Volume) _then;

/// Create a copy of ControlActionDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? volume = null,}) {
  return _then(ControlActionDto_Volume(
volume: null == volume ? _self.volume : volume // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class ControlActionDto_Repeat extends ControlActionDto {
  const ControlActionDto_Repeat({required this.mode}): super._();
  

/// 新的循环模式。
 final  RepeatModeDto mode;

/// Create a copy of ControlActionDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ControlActionDto_RepeatCopyWith<ControlActionDto_Repeat> get copyWith => _$ControlActionDto_RepeatCopyWithImpl<ControlActionDto_Repeat>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ControlActionDto_Repeat&&(identical(other.mode, mode) || other.mode == mode));
}


@override
int get hashCode {
    return Object.hash(runtimeType,mode);
}

@override
String toString() {
    return 'ControlActionDto.repeat(mode: $mode)';
}


}

/// @nodoc
abstract mixin class $ControlActionDto_RepeatCopyWith<$Res> implements $ControlActionDtoCopyWith<$Res> {
  factory $ControlActionDto_RepeatCopyWith(ControlActionDto_Repeat value, $Res Function(ControlActionDto_Repeat) _then) = _$ControlActionDto_RepeatCopyWithImpl;
@useResult
$Res call({
 RepeatModeDto mode
});




}
/// @nodoc
class _$ControlActionDto_RepeatCopyWithImpl<$Res>
    implements $ControlActionDto_RepeatCopyWith<$Res> {
  _$ControlActionDto_RepeatCopyWithImpl(this._self, this._then);

  final ControlActionDto_Repeat _self;
  final $Res Function(ControlActionDto_Repeat) _then;

/// Create a copy of ControlActionDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? mode = null,}) {
  return _then(ControlActionDto_Repeat(
mode: null == mode ? _self.mode : mode // ignore: cast_nullable_to_non_nullable
as RepeatModeDto,
  ));
}


}

/// @nodoc


class ControlActionDto_Shuffle extends ControlActionDto {
  const ControlActionDto_Shuffle({required this.mode}): super._();
  

/// 新的随机模式。
 final  ShuffleModeDto mode;

/// Create a copy of ControlActionDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ControlActionDto_ShuffleCopyWith<ControlActionDto_Shuffle> get copyWith => _$ControlActionDto_ShuffleCopyWithImpl<ControlActionDto_Shuffle>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ControlActionDto_Shuffle&&(identical(other.mode, mode) || other.mode == mode));
}


@override
int get hashCode {
    return Object.hash(runtimeType,mode);
}

@override
String toString() {
    return 'ControlActionDto.shuffle(mode: $mode)';
}


}

/// @nodoc
abstract mixin class $ControlActionDto_ShuffleCopyWith<$Res> implements $ControlActionDtoCopyWith<$Res> {
  factory $ControlActionDto_ShuffleCopyWith(ControlActionDto_Shuffle value, $Res Function(ControlActionDto_Shuffle) _then) = _$ControlActionDto_ShuffleCopyWithImpl;
@useResult
$Res call({
 ShuffleModeDto mode
});




}
/// @nodoc
class _$ControlActionDto_ShuffleCopyWithImpl<$Res>
    implements $ControlActionDto_ShuffleCopyWith<$Res> {
  _$ControlActionDto_ShuffleCopyWithImpl(this._self, this._then);

  final ControlActionDto_Shuffle _self;
  final $Res Function(ControlActionDto_Shuffle) _then;

/// Create a copy of ControlActionDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? mode = null,}) {
  return _then(ControlActionDto_Shuffle(
mode: null == mode ? _self.mode : mode // ignore: cast_nullable_to_non_nullable
as ShuffleModeDto,
  ));
}


}

/// @nodoc


class ControlActionDto_PlayIndex extends ControlActionDto {
  const ControlActionDto_PlayIndex({required this.index}): super._();
  

/// 队列下标（越界时取最后一首）。
 final  int index;

/// Create a copy of ControlActionDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ControlActionDto_PlayIndexCopyWith<ControlActionDto_PlayIndex> get copyWith => _$ControlActionDto_PlayIndexCopyWithImpl<ControlActionDto_PlayIndex>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ControlActionDto_PlayIndex&&(identical(other.index, index) || other.index == index));
}


@override
int get hashCode {
    return Object.hash(runtimeType,index);
}

@override
String toString() {
    return 'ControlActionDto.playIndex(index: $index)';
}


}

/// @nodoc
abstract mixin class $ControlActionDto_PlayIndexCopyWith<$Res> implements $ControlActionDtoCopyWith<$Res> {
  factory $ControlActionDto_PlayIndexCopyWith(ControlActionDto_PlayIndex value, $Res Function(ControlActionDto_PlayIndex) _then) = _$ControlActionDto_PlayIndexCopyWithImpl;
@useResult
$Res call({
 int index
});




}
/// @nodoc
class _$ControlActionDto_PlayIndexCopyWithImpl<$Res>
    implements $ControlActionDto_PlayIndexCopyWith<$Res> {
  _$ControlActionDto_PlayIndexCopyWithImpl(this._self, this._then);

  final ControlActionDto_PlayIndex _self;
  final $Res Function(ControlActionDto_PlayIndex) _then;

/// Create a copy of ControlActionDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? index = null,}) {
  return _then(ControlActionDto_PlayIndex(
index: null == index ? _self.index : index // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc
mixin _$CoreEventDto {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CoreEventDto);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'CoreEventDto()';
}


}

/// @nodoc
class $CoreEventDtoCopyWith<$Res>  {
$CoreEventDtoCopyWith(CoreEventDto _, $Res Function(CoreEventDto) __);
}


/// Adds pattern-matching-related methods to [CoreEventDto].
extension CoreEventDtoPatterns on CoreEventDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( CoreEventDto_PlaybackChanged value)?  playbackChanged,TResult Function( CoreEventDto_PositionTick value)?  positionTick,TResult Function( CoreEventDto_QueueChanged value)?  queueChanged,TResult Function( CoreEventDto_ScanProgress value)?  scanProgress,TResult Function( CoreEventDto_ScanFinished value)?  scanFinished,TResult Function( CoreEventDto_LibraryChanged value)?  libraryChanged,TResult Function( CoreEventDto_EnrichQueueChanged value)?  enrichQueueChanged,TResult Function( CoreEventDto_SyncStatus value)?  syncStatus,TResult Function( CoreEventDto_SourceReachability value)?  sourceReachability,TResult Function( CoreEventDto_ScanFailed value)?  scanFailed,TResult Function( CoreEventDto_PlaybackOptionsChanged value)?  playbackOptionsChanged,TResult Function( CoreEventDto_OfflineProgress value)?  offlineProgress,TResult Function( CoreEventDto_OfflineChanged value)?  offlineChanged,TResult Function( CoreEventDto_OfflineRemoved value)?  offlineRemoved,required TResult orElse(),}){
final _that = this;
switch (_that) {
case CoreEventDto_PlaybackChanged() when playbackChanged != null:
return playbackChanged(_that);case CoreEventDto_PositionTick() when positionTick != null:
return positionTick(_that);case CoreEventDto_QueueChanged() when queueChanged != null:
return queueChanged(_that);case CoreEventDto_ScanProgress() when scanProgress != null:
return scanProgress(_that);case CoreEventDto_ScanFinished() when scanFinished != null:
return scanFinished(_that);case CoreEventDto_LibraryChanged() when libraryChanged != null:
return libraryChanged(_that);case CoreEventDto_EnrichQueueChanged() when enrichQueueChanged != null:
return enrichQueueChanged(_that);case CoreEventDto_SyncStatus() when syncStatus != null:
return syncStatus(_that);case CoreEventDto_SourceReachability() when sourceReachability != null:
return sourceReachability(_that);case CoreEventDto_ScanFailed() when scanFailed != null:
return scanFailed(_that);case CoreEventDto_PlaybackOptionsChanged() when playbackOptionsChanged != null:
return playbackOptionsChanged(_that);case CoreEventDto_OfflineProgress() when offlineProgress != null:
return offlineProgress(_that);case CoreEventDto_OfflineChanged() when offlineChanged != null:
return offlineChanged(_that);case CoreEventDto_OfflineRemoved() when offlineRemoved != null:
return offlineRemoved(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( CoreEventDto_PlaybackChanged value)  playbackChanged,required TResult Function( CoreEventDto_PositionTick value)  positionTick,required TResult Function( CoreEventDto_QueueChanged value)  queueChanged,required TResult Function( CoreEventDto_ScanProgress value)  scanProgress,required TResult Function( CoreEventDto_ScanFinished value)  scanFinished,required TResult Function( CoreEventDto_LibraryChanged value)  libraryChanged,required TResult Function( CoreEventDto_EnrichQueueChanged value)  enrichQueueChanged,required TResult Function( CoreEventDto_SyncStatus value)  syncStatus,required TResult Function( CoreEventDto_SourceReachability value)  sourceReachability,required TResult Function( CoreEventDto_ScanFailed value)  scanFailed,required TResult Function( CoreEventDto_PlaybackOptionsChanged value)  playbackOptionsChanged,required TResult Function( CoreEventDto_OfflineProgress value)  offlineProgress,required TResult Function( CoreEventDto_OfflineChanged value)  offlineChanged,required TResult Function( CoreEventDto_OfflineRemoved value)  offlineRemoved,}){
final _that = this;
switch (_that) {
case CoreEventDto_PlaybackChanged():
return playbackChanged(_that);case CoreEventDto_PositionTick():
return positionTick(_that);case CoreEventDto_QueueChanged():
return queueChanged(_that);case CoreEventDto_ScanProgress():
return scanProgress(_that);case CoreEventDto_ScanFinished():
return scanFinished(_that);case CoreEventDto_LibraryChanged():
return libraryChanged(_that);case CoreEventDto_EnrichQueueChanged():
return enrichQueueChanged(_that);case CoreEventDto_SyncStatus():
return syncStatus(_that);case CoreEventDto_SourceReachability():
return sourceReachability(_that);case CoreEventDto_ScanFailed():
return scanFailed(_that);case CoreEventDto_PlaybackOptionsChanged():
return playbackOptionsChanged(_that);case CoreEventDto_OfflineProgress():
return offlineProgress(_that);case CoreEventDto_OfflineChanged():
return offlineChanged(_that);case CoreEventDto_OfflineRemoved():
return offlineRemoved(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( CoreEventDto_PlaybackChanged value)?  playbackChanged,TResult? Function( CoreEventDto_PositionTick value)?  positionTick,TResult? Function( CoreEventDto_QueueChanged value)?  queueChanged,TResult? Function( CoreEventDto_ScanProgress value)?  scanProgress,TResult? Function( CoreEventDto_ScanFinished value)?  scanFinished,TResult? Function( CoreEventDto_LibraryChanged value)?  libraryChanged,TResult? Function( CoreEventDto_EnrichQueueChanged value)?  enrichQueueChanged,TResult? Function( CoreEventDto_SyncStatus value)?  syncStatus,TResult? Function( CoreEventDto_SourceReachability value)?  sourceReachability,TResult? Function( CoreEventDto_ScanFailed value)?  scanFailed,TResult? Function( CoreEventDto_PlaybackOptionsChanged value)?  playbackOptionsChanged,TResult? Function( CoreEventDto_OfflineProgress value)?  offlineProgress,TResult? Function( CoreEventDto_OfflineChanged value)?  offlineChanged,TResult? Function( CoreEventDto_OfflineRemoved value)?  offlineRemoved,}){
final _that = this;
switch (_that) {
case CoreEventDto_PlaybackChanged() when playbackChanged != null:
return playbackChanged(_that);case CoreEventDto_PositionTick() when positionTick != null:
return positionTick(_that);case CoreEventDto_QueueChanged() when queueChanged != null:
return queueChanged(_that);case CoreEventDto_ScanProgress() when scanProgress != null:
return scanProgress(_that);case CoreEventDto_ScanFinished() when scanFinished != null:
return scanFinished(_that);case CoreEventDto_LibraryChanged() when libraryChanged != null:
return libraryChanged(_that);case CoreEventDto_EnrichQueueChanged() when enrichQueueChanged != null:
return enrichQueueChanged(_that);case CoreEventDto_SyncStatus() when syncStatus != null:
return syncStatus(_that);case CoreEventDto_SourceReachability() when sourceReachability != null:
return sourceReachability(_that);case CoreEventDto_ScanFailed() when scanFailed != null:
return scanFailed(_that);case CoreEventDto_PlaybackOptionsChanged() when playbackOptionsChanged != null:
return playbackOptionsChanged(_that);case CoreEventDto_OfflineProgress() when offlineProgress != null:
return offlineProgress(_that);case CoreEventDto_OfflineChanged() when offlineChanged != null:
return offlineChanged(_that);case CoreEventDto_OfflineRemoved() when offlineRemoved != null:
return offlineRemoved(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( PlaybackStateDto state,  PlatformInt64? trackId,  BigInt positionMs,  BigInt durationMs)?  playbackChanged,TResult Function( BigInt positionMs,  BigInt bufferedMs)?  positionTick,TResult Function( int length,  int? currentIndex)?  queueChanged,TResult Function( PlatformInt64 sourceId,  ScanPhaseDto phase,  BigInt done,  BigInt? total)?  scanProgress,TResult Function( PlatformInt64 sourceId,  BigInt added,  BigInt updated,  BigInt removed)?  scanFinished,TResult Function( LibraryScopeDto scope)?  libraryChanged,TResult Function( int pending)?  enrichQueueChanged,TResult Function( SyncStateDto state)?  syncStatus,TResult Function( PlatformInt64 sourceId,  bool reachable)?  sourceReachability,TResult Function( PlatformInt64 sourceId,  ErrorKind kind,  String detail)?  scanFailed,TResult Function( RepeatModeDto repeat,  ShuffleModeDto shuffle,  double volume,  bool gapless)?  playbackOptionsChanged,TResult Function( PlatformInt64 trackId,  BigInt downloaded,  BigInt? total)?  offlineProgress,TResult Function( PlatformInt64 trackId,  OfflineStateDto state,  String? error)?  offlineChanged,TResult Function( PlatformInt64 trackId)?  offlineRemoved,required TResult orElse(),}) {final _that = this;
switch (_that) {
case CoreEventDto_PlaybackChanged() when playbackChanged != null:
return playbackChanged(_that.state,_that.trackId,_that.positionMs,_that.durationMs);case CoreEventDto_PositionTick() when positionTick != null:
return positionTick(_that.positionMs,_that.bufferedMs);case CoreEventDto_QueueChanged() when queueChanged != null:
return queueChanged(_that.length,_that.currentIndex);case CoreEventDto_ScanProgress() when scanProgress != null:
return scanProgress(_that.sourceId,_that.phase,_that.done,_that.total);case CoreEventDto_ScanFinished() when scanFinished != null:
return scanFinished(_that.sourceId,_that.added,_that.updated,_that.removed);case CoreEventDto_LibraryChanged() when libraryChanged != null:
return libraryChanged(_that.scope);case CoreEventDto_EnrichQueueChanged() when enrichQueueChanged != null:
return enrichQueueChanged(_that.pending);case CoreEventDto_SyncStatus() when syncStatus != null:
return syncStatus(_that.state);case CoreEventDto_SourceReachability() when sourceReachability != null:
return sourceReachability(_that.sourceId,_that.reachable);case CoreEventDto_ScanFailed() when scanFailed != null:
return scanFailed(_that.sourceId,_that.kind,_that.detail);case CoreEventDto_PlaybackOptionsChanged() when playbackOptionsChanged != null:
return playbackOptionsChanged(_that.repeat,_that.shuffle,_that.volume,_that.gapless);case CoreEventDto_OfflineProgress() when offlineProgress != null:
return offlineProgress(_that.trackId,_that.downloaded,_that.total);case CoreEventDto_OfflineChanged() when offlineChanged != null:
return offlineChanged(_that.trackId,_that.state,_that.error);case CoreEventDto_OfflineRemoved() when offlineRemoved != null:
return offlineRemoved(_that.trackId);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( PlaybackStateDto state,  PlatformInt64? trackId,  BigInt positionMs,  BigInt durationMs)  playbackChanged,required TResult Function( BigInt positionMs,  BigInt bufferedMs)  positionTick,required TResult Function( int length,  int? currentIndex)  queueChanged,required TResult Function( PlatformInt64 sourceId,  ScanPhaseDto phase,  BigInt done,  BigInt? total)  scanProgress,required TResult Function( PlatformInt64 sourceId,  BigInt added,  BigInt updated,  BigInt removed)  scanFinished,required TResult Function( LibraryScopeDto scope)  libraryChanged,required TResult Function( int pending)  enrichQueueChanged,required TResult Function( SyncStateDto state)  syncStatus,required TResult Function( PlatformInt64 sourceId,  bool reachable)  sourceReachability,required TResult Function( PlatformInt64 sourceId,  ErrorKind kind,  String detail)  scanFailed,required TResult Function( RepeatModeDto repeat,  ShuffleModeDto shuffle,  double volume,  bool gapless)  playbackOptionsChanged,required TResult Function( PlatformInt64 trackId,  BigInt downloaded,  BigInt? total)  offlineProgress,required TResult Function( PlatformInt64 trackId,  OfflineStateDto state,  String? error)  offlineChanged,required TResult Function( PlatformInt64 trackId)  offlineRemoved,}) {final _that = this;
switch (_that) {
case CoreEventDto_PlaybackChanged():
return playbackChanged(_that.state,_that.trackId,_that.positionMs,_that.durationMs);case CoreEventDto_PositionTick():
return positionTick(_that.positionMs,_that.bufferedMs);case CoreEventDto_QueueChanged():
return queueChanged(_that.length,_that.currentIndex);case CoreEventDto_ScanProgress():
return scanProgress(_that.sourceId,_that.phase,_that.done,_that.total);case CoreEventDto_ScanFinished():
return scanFinished(_that.sourceId,_that.added,_that.updated,_that.removed);case CoreEventDto_LibraryChanged():
return libraryChanged(_that.scope);case CoreEventDto_EnrichQueueChanged():
return enrichQueueChanged(_that.pending);case CoreEventDto_SyncStatus():
return syncStatus(_that.state);case CoreEventDto_SourceReachability():
return sourceReachability(_that.sourceId,_that.reachable);case CoreEventDto_ScanFailed():
return scanFailed(_that.sourceId,_that.kind,_that.detail);case CoreEventDto_PlaybackOptionsChanged():
return playbackOptionsChanged(_that.repeat,_that.shuffle,_that.volume,_that.gapless);case CoreEventDto_OfflineProgress():
return offlineProgress(_that.trackId,_that.downloaded,_that.total);case CoreEventDto_OfflineChanged():
return offlineChanged(_that.trackId,_that.state,_that.error);case CoreEventDto_OfflineRemoved():
return offlineRemoved(_that.trackId);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( PlaybackStateDto state,  PlatformInt64? trackId,  BigInt positionMs,  BigInt durationMs)?  playbackChanged,TResult? Function( BigInt positionMs,  BigInt bufferedMs)?  positionTick,TResult? Function( int length,  int? currentIndex)?  queueChanged,TResult? Function( PlatformInt64 sourceId,  ScanPhaseDto phase,  BigInt done,  BigInt? total)?  scanProgress,TResult? Function( PlatformInt64 sourceId,  BigInt added,  BigInt updated,  BigInt removed)?  scanFinished,TResult? Function( LibraryScopeDto scope)?  libraryChanged,TResult? Function( int pending)?  enrichQueueChanged,TResult? Function( SyncStateDto state)?  syncStatus,TResult? Function( PlatformInt64 sourceId,  bool reachable)?  sourceReachability,TResult? Function( PlatformInt64 sourceId,  ErrorKind kind,  String detail)?  scanFailed,TResult? Function( RepeatModeDto repeat,  ShuffleModeDto shuffle,  double volume,  bool gapless)?  playbackOptionsChanged,TResult? Function( PlatformInt64 trackId,  BigInt downloaded,  BigInt? total)?  offlineProgress,TResult? Function( PlatformInt64 trackId,  OfflineStateDto state,  String? error)?  offlineChanged,TResult? Function( PlatformInt64 trackId)?  offlineRemoved,}) {final _that = this;
switch (_that) {
case CoreEventDto_PlaybackChanged() when playbackChanged != null:
return playbackChanged(_that.state,_that.trackId,_that.positionMs,_that.durationMs);case CoreEventDto_PositionTick() when positionTick != null:
return positionTick(_that.positionMs,_that.bufferedMs);case CoreEventDto_QueueChanged() when queueChanged != null:
return queueChanged(_that.length,_that.currentIndex);case CoreEventDto_ScanProgress() when scanProgress != null:
return scanProgress(_that.sourceId,_that.phase,_that.done,_that.total);case CoreEventDto_ScanFinished() when scanFinished != null:
return scanFinished(_that.sourceId,_that.added,_that.updated,_that.removed);case CoreEventDto_LibraryChanged() when libraryChanged != null:
return libraryChanged(_that.scope);case CoreEventDto_EnrichQueueChanged() when enrichQueueChanged != null:
return enrichQueueChanged(_that.pending);case CoreEventDto_SyncStatus() when syncStatus != null:
return syncStatus(_that.state);case CoreEventDto_SourceReachability() when sourceReachability != null:
return sourceReachability(_that.sourceId,_that.reachable);case CoreEventDto_ScanFailed() when scanFailed != null:
return scanFailed(_that.sourceId,_that.kind,_that.detail);case CoreEventDto_PlaybackOptionsChanged() when playbackOptionsChanged != null:
return playbackOptionsChanged(_that.repeat,_that.shuffle,_that.volume,_that.gapless);case CoreEventDto_OfflineProgress() when offlineProgress != null:
return offlineProgress(_that.trackId,_that.downloaded,_that.total);case CoreEventDto_OfflineChanged() when offlineChanged != null:
return offlineChanged(_that.trackId,_that.state,_that.error);case CoreEventDto_OfflineRemoved() when offlineRemoved != null:
return offlineRemoved(_that.trackId);case _:
  return null;

}
}

}

/// @nodoc


class CoreEventDto_PlaybackChanged extends CoreEventDto {
  const CoreEventDto_PlaybackChanged({required this.state, this.trackId, required this.positionMs, required this.durationMs}): super._();
  

 final  PlaybackStateDto state;
 final  PlatformInt64? trackId;
 final  BigInt positionMs;
 final  BigInt durationMs;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CoreEventDto_PlaybackChangedCopyWith<CoreEventDto_PlaybackChanged> get copyWith => _$CoreEventDto_PlaybackChangedCopyWithImpl<CoreEventDto_PlaybackChanged>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CoreEventDto_PlaybackChanged&&(identical(other.state, state) || other.state == state)&&(identical(other.trackId, trackId) || other.trackId == trackId)&&(identical(other.positionMs, positionMs) || other.positionMs == positionMs)&&(identical(other.durationMs, durationMs) || other.durationMs == durationMs));
}


@override
int get hashCode {
    return Object.hash(runtimeType,state,trackId,positionMs,durationMs);
}

@override
String toString() {
    return 'CoreEventDto.playbackChanged(state: $state, trackId: $trackId, positionMs: $positionMs, durationMs: $durationMs)';
}


}

/// @nodoc
abstract mixin class $CoreEventDto_PlaybackChangedCopyWith<$Res> implements $CoreEventDtoCopyWith<$Res> {
  factory $CoreEventDto_PlaybackChangedCopyWith(CoreEventDto_PlaybackChanged value, $Res Function(CoreEventDto_PlaybackChanged) _then) = _$CoreEventDto_PlaybackChangedCopyWithImpl;
@useResult
$Res call({
 PlaybackStateDto state, PlatformInt64? trackId, BigInt positionMs, BigInt durationMs
});




}
/// @nodoc
class _$CoreEventDto_PlaybackChangedCopyWithImpl<$Res>
    implements $CoreEventDto_PlaybackChangedCopyWith<$Res> {
  _$CoreEventDto_PlaybackChangedCopyWithImpl(this._self, this._then);

  final CoreEventDto_PlaybackChanged _self;
  final $Res Function(CoreEventDto_PlaybackChanged) _then;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? state = null,Object? trackId = freezed,Object? positionMs = null,Object? durationMs = null,}) {
  return _then(CoreEventDto_PlaybackChanged(
state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as PlaybackStateDto,trackId: freezed == trackId ? _self.trackId : trackId // ignore: cast_nullable_to_non_nullable
as PlatformInt64?,positionMs: null == positionMs ? _self.positionMs : positionMs // ignore: cast_nullable_to_non_nullable
as BigInt,durationMs: null == durationMs ? _self.durationMs : durationMs // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class CoreEventDto_PositionTick extends CoreEventDto {
  const CoreEventDto_PositionTick({required this.positionMs, required this.bufferedMs}): super._();
  

 final  BigInt positionMs;
 final  BigInt bufferedMs;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CoreEventDto_PositionTickCopyWith<CoreEventDto_PositionTick> get copyWith => _$CoreEventDto_PositionTickCopyWithImpl<CoreEventDto_PositionTick>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CoreEventDto_PositionTick&&(identical(other.positionMs, positionMs) || other.positionMs == positionMs)&&(identical(other.bufferedMs, bufferedMs) || other.bufferedMs == bufferedMs));
}


@override
int get hashCode {
    return Object.hash(runtimeType,positionMs,bufferedMs);
}

@override
String toString() {
    return 'CoreEventDto.positionTick(positionMs: $positionMs, bufferedMs: $bufferedMs)';
}


}

/// @nodoc
abstract mixin class $CoreEventDto_PositionTickCopyWith<$Res> implements $CoreEventDtoCopyWith<$Res> {
  factory $CoreEventDto_PositionTickCopyWith(CoreEventDto_PositionTick value, $Res Function(CoreEventDto_PositionTick) _then) = _$CoreEventDto_PositionTickCopyWithImpl;
@useResult
$Res call({
 BigInt positionMs, BigInt bufferedMs
});




}
/// @nodoc
class _$CoreEventDto_PositionTickCopyWithImpl<$Res>
    implements $CoreEventDto_PositionTickCopyWith<$Res> {
  _$CoreEventDto_PositionTickCopyWithImpl(this._self, this._then);

  final CoreEventDto_PositionTick _self;
  final $Res Function(CoreEventDto_PositionTick) _then;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? positionMs = null,Object? bufferedMs = null,}) {
  return _then(CoreEventDto_PositionTick(
positionMs: null == positionMs ? _self.positionMs : positionMs // ignore: cast_nullable_to_non_nullable
as BigInt,bufferedMs: null == bufferedMs ? _self.bufferedMs : bufferedMs // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class CoreEventDto_QueueChanged extends CoreEventDto {
  const CoreEventDto_QueueChanged({required this.length, this.currentIndex}): super._();
  

 final  int length;
 final  int? currentIndex;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CoreEventDto_QueueChangedCopyWith<CoreEventDto_QueueChanged> get copyWith => _$CoreEventDto_QueueChangedCopyWithImpl<CoreEventDto_QueueChanged>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CoreEventDto_QueueChanged&&(identical(other.length, length) || other.length == length)&&(identical(other.currentIndex, currentIndex) || other.currentIndex == currentIndex));
}


@override
int get hashCode {
    return Object.hash(runtimeType,length,currentIndex);
}

@override
String toString() {
    return 'CoreEventDto.queueChanged(length: $length, currentIndex: $currentIndex)';
}


}

/// @nodoc
abstract mixin class $CoreEventDto_QueueChangedCopyWith<$Res> implements $CoreEventDtoCopyWith<$Res> {
  factory $CoreEventDto_QueueChangedCopyWith(CoreEventDto_QueueChanged value, $Res Function(CoreEventDto_QueueChanged) _then) = _$CoreEventDto_QueueChangedCopyWithImpl;
@useResult
$Res call({
 int length, int? currentIndex
});




}
/// @nodoc
class _$CoreEventDto_QueueChangedCopyWithImpl<$Res>
    implements $CoreEventDto_QueueChangedCopyWith<$Res> {
  _$CoreEventDto_QueueChangedCopyWithImpl(this._self, this._then);

  final CoreEventDto_QueueChanged _self;
  final $Res Function(CoreEventDto_QueueChanged) _then;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? length = null,Object? currentIndex = freezed,}) {
  return _then(CoreEventDto_QueueChanged(
length: null == length ? _self.length : length // ignore: cast_nullable_to_non_nullable
as int,currentIndex: freezed == currentIndex ? _self.currentIndex : currentIndex // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}


}

/// @nodoc


class CoreEventDto_ScanProgress extends CoreEventDto {
  const CoreEventDto_ScanProgress({required this.sourceId, required this.phase, required this.done, this.total}): super._();
  

 final  PlatformInt64 sourceId;
 final  ScanPhaseDto phase;
 final  BigInt done;
 final  BigInt? total;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CoreEventDto_ScanProgressCopyWith<CoreEventDto_ScanProgress> get copyWith => _$CoreEventDto_ScanProgressCopyWithImpl<CoreEventDto_ScanProgress>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CoreEventDto_ScanProgress&&(identical(other.sourceId, sourceId) || other.sourceId == sourceId)&&(identical(other.phase, phase) || other.phase == phase)&&(identical(other.done, done) || other.done == done)&&(identical(other.total, total) || other.total == total));
}


@override
int get hashCode {
    return Object.hash(runtimeType,sourceId,phase,done,total);
}

@override
String toString() {
    return 'CoreEventDto.scanProgress(sourceId: $sourceId, phase: $phase, done: $done, total: $total)';
}


}

/// @nodoc
abstract mixin class $CoreEventDto_ScanProgressCopyWith<$Res> implements $CoreEventDtoCopyWith<$Res> {
  factory $CoreEventDto_ScanProgressCopyWith(CoreEventDto_ScanProgress value, $Res Function(CoreEventDto_ScanProgress) _then) = _$CoreEventDto_ScanProgressCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 sourceId, ScanPhaseDto phase, BigInt done, BigInt? total
});




}
/// @nodoc
class _$CoreEventDto_ScanProgressCopyWithImpl<$Res>
    implements $CoreEventDto_ScanProgressCopyWith<$Res> {
  _$CoreEventDto_ScanProgressCopyWithImpl(this._self, this._then);

  final CoreEventDto_ScanProgress _self;
  final $Res Function(CoreEventDto_ScanProgress) _then;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sourceId = null,Object? phase = null,Object? done = null,Object? total = freezed,}) {
  return _then(CoreEventDto_ScanProgress(
sourceId: null == sourceId ? _self.sourceId : sourceId // ignore: cast_nullable_to_non_nullable
as PlatformInt64,phase: null == phase ? _self.phase : phase // ignore: cast_nullable_to_non_nullable
as ScanPhaseDto,done: null == done ? _self.done : done // ignore: cast_nullable_to_non_nullable
as BigInt,total: freezed == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as BigInt?,
  ));
}


}

/// @nodoc


class CoreEventDto_ScanFinished extends CoreEventDto {
  const CoreEventDto_ScanFinished({required this.sourceId, required this.added, required this.updated, required this.removed}): super._();
  

 final  PlatformInt64 sourceId;
 final  BigInt added;
 final  BigInt updated;
 final  BigInt removed;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CoreEventDto_ScanFinishedCopyWith<CoreEventDto_ScanFinished> get copyWith => _$CoreEventDto_ScanFinishedCopyWithImpl<CoreEventDto_ScanFinished>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CoreEventDto_ScanFinished&&(identical(other.sourceId, sourceId) || other.sourceId == sourceId)&&(identical(other.added, added) || other.added == added)&&(identical(other.updated, updated) || other.updated == updated)&&(identical(other.removed, removed) || other.removed == removed));
}


@override
int get hashCode {
    return Object.hash(runtimeType,sourceId,added,updated,removed);
}

@override
String toString() {
    return 'CoreEventDto.scanFinished(sourceId: $sourceId, added: $added, updated: $updated, removed: $removed)';
}


}

/// @nodoc
abstract mixin class $CoreEventDto_ScanFinishedCopyWith<$Res> implements $CoreEventDtoCopyWith<$Res> {
  factory $CoreEventDto_ScanFinishedCopyWith(CoreEventDto_ScanFinished value, $Res Function(CoreEventDto_ScanFinished) _then) = _$CoreEventDto_ScanFinishedCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 sourceId, BigInt added, BigInt updated, BigInt removed
});




}
/// @nodoc
class _$CoreEventDto_ScanFinishedCopyWithImpl<$Res>
    implements $CoreEventDto_ScanFinishedCopyWith<$Res> {
  _$CoreEventDto_ScanFinishedCopyWithImpl(this._self, this._then);

  final CoreEventDto_ScanFinished _self;
  final $Res Function(CoreEventDto_ScanFinished) _then;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sourceId = null,Object? added = null,Object? updated = null,Object? removed = null,}) {
  return _then(CoreEventDto_ScanFinished(
sourceId: null == sourceId ? _self.sourceId : sourceId // ignore: cast_nullable_to_non_nullable
as PlatformInt64,added: null == added ? _self.added : added // ignore: cast_nullable_to_non_nullable
as BigInt,updated: null == updated ? _self.updated : updated // ignore: cast_nullable_to_non_nullable
as BigInt,removed: null == removed ? _self.removed : removed // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class CoreEventDto_LibraryChanged extends CoreEventDto {
  const CoreEventDto_LibraryChanged({required this.scope}): super._();
  

 final  LibraryScopeDto scope;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CoreEventDto_LibraryChangedCopyWith<CoreEventDto_LibraryChanged> get copyWith => _$CoreEventDto_LibraryChangedCopyWithImpl<CoreEventDto_LibraryChanged>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CoreEventDto_LibraryChanged&&(identical(other.scope, scope) || other.scope == scope));
}


@override
int get hashCode {
    return Object.hash(runtimeType,scope);
}

@override
String toString() {
    return 'CoreEventDto.libraryChanged(scope: $scope)';
}


}

/// @nodoc
abstract mixin class $CoreEventDto_LibraryChangedCopyWith<$Res> implements $CoreEventDtoCopyWith<$Res> {
  factory $CoreEventDto_LibraryChangedCopyWith(CoreEventDto_LibraryChanged value, $Res Function(CoreEventDto_LibraryChanged) _then) = _$CoreEventDto_LibraryChangedCopyWithImpl;
@useResult
$Res call({
 LibraryScopeDto scope
});




}
/// @nodoc
class _$CoreEventDto_LibraryChangedCopyWithImpl<$Res>
    implements $CoreEventDto_LibraryChangedCopyWith<$Res> {
  _$CoreEventDto_LibraryChangedCopyWithImpl(this._self, this._then);

  final CoreEventDto_LibraryChanged _self;
  final $Res Function(CoreEventDto_LibraryChanged) _then;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? scope = null,}) {
  return _then(CoreEventDto_LibraryChanged(
scope: null == scope ? _self.scope : scope // ignore: cast_nullable_to_non_nullable
as LibraryScopeDto,
  ));
}


}

/// @nodoc


class CoreEventDto_EnrichQueueChanged extends CoreEventDto {
  const CoreEventDto_EnrichQueueChanged({required this.pending}): super._();
  

 final  int pending;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CoreEventDto_EnrichQueueChangedCopyWith<CoreEventDto_EnrichQueueChanged> get copyWith => _$CoreEventDto_EnrichQueueChangedCopyWithImpl<CoreEventDto_EnrichQueueChanged>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CoreEventDto_EnrichQueueChanged&&(identical(other.pending, pending) || other.pending == pending));
}


@override
int get hashCode {
    return Object.hash(runtimeType,pending);
}

@override
String toString() {
    return 'CoreEventDto.enrichQueueChanged(pending: $pending)';
}


}

/// @nodoc
abstract mixin class $CoreEventDto_EnrichQueueChangedCopyWith<$Res> implements $CoreEventDtoCopyWith<$Res> {
  factory $CoreEventDto_EnrichQueueChangedCopyWith(CoreEventDto_EnrichQueueChanged value, $Res Function(CoreEventDto_EnrichQueueChanged) _then) = _$CoreEventDto_EnrichQueueChangedCopyWithImpl;
@useResult
$Res call({
 int pending
});




}
/// @nodoc
class _$CoreEventDto_EnrichQueueChangedCopyWithImpl<$Res>
    implements $CoreEventDto_EnrichQueueChangedCopyWith<$Res> {
  _$CoreEventDto_EnrichQueueChangedCopyWithImpl(this._self, this._then);

  final CoreEventDto_EnrichQueueChanged _self;
  final $Res Function(CoreEventDto_EnrichQueueChanged) _then;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? pending = null,}) {
  return _then(CoreEventDto_EnrichQueueChanged(
pending: null == pending ? _self.pending : pending // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class CoreEventDto_SyncStatus extends CoreEventDto {
  const CoreEventDto_SyncStatus({required this.state}): super._();
  

 final  SyncStateDto state;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CoreEventDto_SyncStatusCopyWith<CoreEventDto_SyncStatus> get copyWith => _$CoreEventDto_SyncStatusCopyWithImpl<CoreEventDto_SyncStatus>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CoreEventDto_SyncStatus&&(identical(other.state, state) || other.state == state));
}


@override
int get hashCode {
    return Object.hash(runtimeType,state);
}

@override
String toString() {
    return 'CoreEventDto.syncStatus(state: $state)';
}


}

/// @nodoc
abstract mixin class $CoreEventDto_SyncStatusCopyWith<$Res> implements $CoreEventDtoCopyWith<$Res> {
  factory $CoreEventDto_SyncStatusCopyWith(CoreEventDto_SyncStatus value, $Res Function(CoreEventDto_SyncStatus) _then) = _$CoreEventDto_SyncStatusCopyWithImpl;
@useResult
$Res call({
 SyncStateDto state
});




}
/// @nodoc
class _$CoreEventDto_SyncStatusCopyWithImpl<$Res>
    implements $CoreEventDto_SyncStatusCopyWith<$Res> {
  _$CoreEventDto_SyncStatusCopyWithImpl(this._self, this._then);

  final CoreEventDto_SyncStatus _self;
  final $Res Function(CoreEventDto_SyncStatus) _then;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? state = null,}) {
  return _then(CoreEventDto_SyncStatus(
state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as SyncStateDto,
  ));
}


}

/// @nodoc


class CoreEventDto_SourceReachability extends CoreEventDto {
  const CoreEventDto_SourceReachability({required this.sourceId, required this.reachable}): super._();
  

 final  PlatformInt64 sourceId;
 final  bool reachable;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CoreEventDto_SourceReachabilityCopyWith<CoreEventDto_SourceReachability> get copyWith => _$CoreEventDto_SourceReachabilityCopyWithImpl<CoreEventDto_SourceReachability>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CoreEventDto_SourceReachability&&(identical(other.sourceId, sourceId) || other.sourceId == sourceId)&&(identical(other.reachable, reachable) || other.reachable == reachable));
}


@override
int get hashCode {
    return Object.hash(runtimeType,sourceId,reachable);
}

@override
String toString() {
    return 'CoreEventDto.sourceReachability(sourceId: $sourceId, reachable: $reachable)';
}


}

/// @nodoc
abstract mixin class $CoreEventDto_SourceReachabilityCopyWith<$Res> implements $CoreEventDtoCopyWith<$Res> {
  factory $CoreEventDto_SourceReachabilityCopyWith(CoreEventDto_SourceReachability value, $Res Function(CoreEventDto_SourceReachability) _then) = _$CoreEventDto_SourceReachabilityCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 sourceId, bool reachable
});




}
/// @nodoc
class _$CoreEventDto_SourceReachabilityCopyWithImpl<$Res>
    implements $CoreEventDto_SourceReachabilityCopyWith<$Res> {
  _$CoreEventDto_SourceReachabilityCopyWithImpl(this._self, this._then);

  final CoreEventDto_SourceReachability _self;
  final $Res Function(CoreEventDto_SourceReachability) _then;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sourceId = null,Object? reachable = null,}) {
  return _then(CoreEventDto_SourceReachability(
sourceId: null == sourceId ? _self.sourceId : sourceId // ignore: cast_nullable_to_non_nullable
as PlatformInt64,reachable: null == reachable ? _self.reachable : reachable // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class CoreEventDto_ScanFailed extends CoreEventDto {
  const CoreEventDto_ScanFailed({required this.sourceId, required this.kind, required this.detail}): super._();
  

 final  PlatformInt64 sourceId;
/// 错误类别（UI 据此显示本地化提示）。
 final  ErrorKind kind;
/// 给开发者看的详情（不直接展示给用户）。
 final  String detail;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CoreEventDto_ScanFailedCopyWith<CoreEventDto_ScanFailed> get copyWith => _$CoreEventDto_ScanFailedCopyWithImpl<CoreEventDto_ScanFailed>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CoreEventDto_ScanFailed&&(identical(other.sourceId, sourceId) || other.sourceId == sourceId)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.detail, detail) || other.detail == detail));
}


@override
int get hashCode {
    return Object.hash(runtimeType,sourceId,kind,detail);
}

@override
String toString() {
    return 'CoreEventDto.scanFailed(sourceId: $sourceId, kind: $kind, detail: $detail)';
}


}

/// @nodoc
abstract mixin class $CoreEventDto_ScanFailedCopyWith<$Res> implements $CoreEventDtoCopyWith<$Res> {
  factory $CoreEventDto_ScanFailedCopyWith(CoreEventDto_ScanFailed value, $Res Function(CoreEventDto_ScanFailed) _then) = _$CoreEventDto_ScanFailedCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 sourceId, ErrorKind kind, String detail
});




}
/// @nodoc
class _$CoreEventDto_ScanFailedCopyWithImpl<$Res>
    implements $CoreEventDto_ScanFailedCopyWith<$Res> {
  _$CoreEventDto_ScanFailedCopyWithImpl(this._self, this._then);

  final CoreEventDto_ScanFailed _self;
  final $Res Function(CoreEventDto_ScanFailed) _then;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sourceId = null,Object? kind = null,Object? detail = null,}) {
  return _then(CoreEventDto_ScanFailed(
sourceId: null == sourceId ? _self.sourceId : sourceId // ignore: cast_nullable_to_non_nullable
as PlatformInt64,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as ErrorKind,detail: null == detail ? _self.detail : detail // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class CoreEventDto_PlaybackOptionsChanged extends CoreEventDto {
  const CoreEventDto_PlaybackOptionsChanged({required this.repeat, required this.shuffle, required this.volume, required this.gapless}): super._();
  

 final  RepeatModeDto repeat;
 final  ShuffleModeDto shuffle;
 final  double volume;
 final  bool gapless;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CoreEventDto_PlaybackOptionsChangedCopyWith<CoreEventDto_PlaybackOptionsChanged> get copyWith => _$CoreEventDto_PlaybackOptionsChangedCopyWithImpl<CoreEventDto_PlaybackOptionsChanged>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CoreEventDto_PlaybackOptionsChanged&&(identical(other.repeat, repeat) || other.repeat == repeat)&&(identical(other.shuffle, shuffle) || other.shuffle == shuffle)&&(identical(other.volume, volume) || other.volume == volume)&&(identical(other.gapless, gapless) || other.gapless == gapless));
}


@override
int get hashCode {
    return Object.hash(runtimeType,repeat,shuffle,volume,gapless);
}

@override
String toString() {
    return 'CoreEventDto.playbackOptionsChanged(repeat: $repeat, shuffle: $shuffle, volume: $volume, gapless: $gapless)';
}


}

/// @nodoc
abstract mixin class $CoreEventDto_PlaybackOptionsChangedCopyWith<$Res> implements $CoreEventDtoCopyWith<$Res> {
  factory $CoreEventDto_PlaybackOptionsChangedCopyWith(CoreEventDto_PlaybackOptionsChanged value, $Res Function(CoreEventDto_PlaybackOptionsChanged) _then) = _$CoreEventDto_PlaybackOptionsChangedCopyWithImpl;
@useResult
$Res call({
 RepeatModeDto repeat, ShuffleModeDto shuffle, double volume, bool gapless
});




}
/// @nodoc
class _$CoreEventDto_PlaybackOptionsChangedCopyWithImpl<$Res>
    implements $CoreEventDto_PlaybackOptionsChangedCopyWith<$Res> {
  _$CoreEventDto_PlaybackOptionsChangedCopyWithImpl(this._self, this._then);

  final CoreEventDto_PlaybackOptionsChanged _self;
  final $Res Function(CoreEventDto_PlaybackOptionsChanged) _then;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? repeat = null,Object? shuffle = null,Object? volume = null,Object? gapless = null,}) {
  return _then(CoreEventDto_PlaybackOptionsChanged(
repeat: null == repeat ? _self.repeat : repeat // ignore: cast_nullable_to_non_nullable
as RepeatModeDto,shuffle: null == shuffle ? _self.shuffle : shuffle // ignore: cast_nullable_to_non_nullable
as ShuffleModeDto,volume: null == volume ? _self.volume : volume // ignore: cast_nullable_to_non_nullable
as double,gapless: null == gapless ? _self.gapless : gapless // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class CoreEventDto_OfflineProgress extends CoreEventDto {
  const CoreEventDto_OfflineProgress({required this.trackId, required this.downloaded, this.total}): super._();
  

 final  PlatformInt64 trackId;
 final  BigInt downloaded;
 final  BigInt? total;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CoreEventDto_OfflineProgressCopyWith<CoreEventDto_OfflineProgress> get copyWith => _$CoreEventDto_OfflineProgressCopyWithImpl<CoreEventDto_OfflineProgress>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CoreEventDto_OfflineProgress&&(identical(other.trackId, trackId) || other.trackId == trackId)&&(identical(other.downloaded, downloaded) || other.downloaded == downloaded)&&(identical(other.total, total) || other.total == total));
}


@override
int get hashCode {
    return Object.hash(runtimeType,trackId,downloaded,total);
}

@override
String toString() {
    return 'CoreEventDto.offlineProgress(trackId: $trackId, downloaded: $downloaded, total: $total)';
}


}

/// @nodoc
abstract mixin class $CoreEventDto_OfflineProgressCopyWith<$Res> implements $CoreEventDtoCopyWith<$Res> {
  factory $CoreEventDto_OfflineProgressCopyWith(CoreEventDto_OfflineProgress value, $Res Function(CoreEventDto_OfflineProgress) _then) = _$CoreEventDto_OfflineProgressCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 trackId, BigInt downloaded, BigInt? total
});




}
/// @nodoc
class _$CoreEventDto_OfflineProgressCopyWithImpl<$Res>
    implements $CoreEventDto_OfflineProgressCopyWith<$Res> {
  _$CoreEventDto_OfflineProgressCopyWithImpl(this._self, this._then);

  final CoreEventDto_OfflineProgress _self;
  final $Res Function(CoreEventDto_OfflineProgress) _then;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? trackId = null,Object? downloaded = null,Object? total = freezed,}) {
  return _then(CoreEventDto_OfflineProgress(
trackId: null == trackId ? _self.trackId : trackId // ignore: cast_nullable_to_non_nullable
as PlatformInt64,downloaded: null == downloaded ? _self.downloaded : downloaded // ignore: cast_nullable_to_non_nullable
as BigInt,total: freezed == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as BigInt?,
  ));
}


}

/// @nodoc


class CoreEventDto_OfflineChanged extends CoreEventDto {
  const CoreEventDto_OfflineChanged({required this.trackId, required this.state, this.error}): super._();
  

 final  PlatformInt64 trackId;
 final  OfflineStateDto state;
 final  String? error;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CoreEventDto_OfflineChangedCopyWith<CoreEventDto_OfflineChanged> get copyWith => _$CoreEventDto_OfflineChangedCopyWithImpl<CoreEventDto_OfflineChanged>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CoreEventDto_OfflineChanged&&(identical(other.trackId, trackId) || other.trackId == trackId)&&(identical(other.state, state) || other.state == state)&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode {
    return Object.hash(runtimeType,trackId,state,error);
}

@override
String toString() {
    return 'CoreEventDto.offlineChanged(trackId: $trackId, state: $state, error: $error)';
}


}

/// @nodoc
abstract mixin class $CoreEventDto_OfflineChangedCopyWith<$Res> implements $CoreEventDtoCopyWith<$Res> {
  factory $CoreEventDto_OfflineChangedCopyWith(CoreEventDto_OfflineChanged value, $Res Function(CoreEventDto_OfflineChanged) _then) = _$CoreEventDto_OfflineChangedCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 trackId, OfflineStateDto state, String? error
});




}
/// @nodoc
class _$CoreEventDto_OfflineChangedCopyWithImpl<$Res>
    implements $CoreEventDto_OfflineChangedCopyWith<$Res> {
  _$CoreEventDto_OfflineChangedCopyWithImpl(this._self, this._then);

  final CoreEventDto_OfflineChanged _self;
  final $Res Function(CoreEventDto_OfflineChanged) _then;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? trackId = null,Object? state = null,Object? error = freezed,}) {
  return _then(CoreEventDto_OfflineChanged(
trackId: null == trackId ? _self.trackId : trackId // ignore: cast_nullable_to_non_nullable
as PlatformInt64,state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as OfflineStateDto,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class CoreEventDto_OfflineRemoved extends CoreEventDto {
  const CoreEventDto_OfflineRemoved({required this.trackId}): super._();
  

 final  PlatformInt64 trackId;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CoreEventDto_OfflineRemovedCopyWith<CoreEventDto_OfflineRemoved> get copyWith => _$CoreEventDto_OfflineRemovedCopyWithImpl<CoreEventDto_OfflineRemoved>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CoreEventDto_OfflineRemoved&&(identical(other.trackId, trackId) || other.trackId == trackId));
}


@override
int get hashCode {
    return Object.hash(runtimeType,trackId);
}

@override
String toString() {
    return 'CoreEventDto.offlineRemoved(trackId: $trackId)';
}


}

/// @nodoc
abstract mixin class $CoreEventDto_OfflineRemovedCopyWith<$Res> implements $CoreEventDtoCopyWith<$Res> {
  factory $CoreEventDto_OfflineRemovedCopyWith(CoreEventDto_OfflineRemoved value, $Res Function(CoreEventDto_OfflineRemoved) _then) = _$CoreEventDto_OfflineRemovedCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 trackId
});




}
/// @nodoc
class _$CoreEventDto_OfflineRemovedCopyWithImpl<$Res>
    implements $CoreEventDto_OfflineRemovedCopyWith<$Res> {
  _$CoreEventDto_OfflineRemovedCopyWithImpl(this._self, this._then);

  final CoreEventDto_OfflineRemoved _self;
  final $Res Function(CoreEventDto_OfflineRemoved) _then;

/// Create a copy of CoreEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? trackId = null,}) {
  return _then(CoreEventDto_OfflineRemoved(
trackId: null == trackId ? _self.trackId : trackId // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc
mixin _$PlayContextDto {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is PlayContextDto);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'PlayContextDto()';
}


}

/// @nodoc
class $PlayContextDtoCopyWith<$Res>  {
$PlayContextDtoCopyWith(PlayContextDto _, $Res Function(PlayContextDto) __);
}


/// Adds pattern-matching-related methods to [PlayContextDto].
extension PlayContextDtoPatterns on PlayContextDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( PlayContextDto_Library value)?  library_,TResult Function( PlayContextDto_Album value)?  album,TResult Function( PlayContextDto_Artist value)?  artist,TResult Function( PlayContextDto_Genre value)?  genre,TResult Function( PlayContextDto_Playlist value)?  playlist,TResult Function( PlayContextDto_Loved value)?  loved,TResult Function( PlayContextDto_Folder value)?  folder,required TResult orElse(),}){
final _that = this;
switch (_that) {
case PlayContextDto_Library() when library_ != null:
return library_(_that);case PlayContextDto_Album() when album != null:
return album(_that);case PlayContextDto_Artist() when artist != null:
return artist(_that);case PlayContextDto_Genre() when genre != null:
return genre(_that);case PlayContextDto_Playlist() when playlist != null:
return playlist(_that);case PlayContextDto_Loved() when loved != null:
return loved(_that);case PlayContextDto_Folder() when folder != null:
return folder(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( PlayContextDto_Library value)  library_,required TResult Function( PlayContextDto_Album value)  album,required TResult Function( PlayContextDto_Artist value)  artist,required TResult Function( PlayContextDto_Genre value)  genre,required TResult Function( PlayContextDto_Playlist value)  playlist,required TResult Function( PlayContextDto_Loved value)  loved,required TResult Function( PlayContextDto_Folder value)  folder,}){
final _that = this;
switch (_that) {
case PlayContextDto_Library():
return library_(_that);case PlayContextDto_Album():
return album(_that);case PlayContextDto_Artist():
return artist(_that);case PlayContextDto_Genre():
return genre(_that);case PlayContextDto_Playlist():
return playlist(_that);case PlayContextDto_Loved():
return loved(_that);case PlayContextDto_Folder():
return folder(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( PlayContextDto_Library value)?  library_,TResult? Function( PlayContextDto_Album value)?  album,TResult? Function( PlayContextDto_Artist value)?  artist,TResult? Function( PlayContextDto_Genre value)?  genre,TResult? Function( PlayContextDto_Playlist value)?  playlist,TResult? Function( PlayContextDto_Loved value)?  loved,TResult? Function( PlayContextDto_Folder value)?  folder,}){
final _that = this;
switch (_that) {
case PlayContextDto_Library() when library_ != null:
return library_(_that);case PlayContextDto_Album() when album != null:
return album(_that);case PlayContextDto_Artist() when artist != null:
return artist(_that);case PlayContextDto_Genre() when genre != null:
return genre(_that);case PlayContextDto_Playlist() when playlist != null:
return playlist(_that);case PlayContextDto_Loved() when loved != null:
return loved(_that);case PlayContextDto_Folder() when folder != null:
return folder(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( TrackSortDto sort)?  library_,TResult Function( PlatformInt64 albumId)?  album,TResult Function( PlatformInt64 artistId)?  artist,TResult Function( String name)?  genre,TResult Function( PlatformInt64 playlistId)?  playlist,TResult Function()?  loved,TResult Function( PlatformInt64 sourceId,  String path)?  folder,required TResult orElse(),}) {final _that = this;
switch (_that) {
case PlayContextDto_Library() when library_ != null:
return library_(_that.sort);case PlayContextDto_Album() when album != null:
return album(_that.albumId);case PlayContextDto_Artist() when artist != null:
return artist(_that.artistId);case PlayContextDto_Genre() when genre != null:
return genre(_that.name);case PlayContextDto_Playlist() when playlist != null:
return playlist(_that.playlistId);case PlayContextDto_Loved() when loved != null:
return loved();case PlayContextDto_Folder() when folder != null:
return folder(_that.sourceId,_that.path);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( TrackSortDto sort)  library_,required TResult Function( PlatformInt64 albumId)  album,required TResult Function( PlatformInt64 artistId)  artist,required TResult Function( String name)  genre,required TResult Function( PlatformInt64 playlistId)  playlist,required TResult Function()  loved,required TResult Function( PlatformInt64 sourceId,  String path)  folder,}) {final _that = this;
switch (_that) {
case PlayContextDto_Library():
return library_(_that.sort);case PlayContextDto_Album():
return album(_that.albumId);case PlayContextDto_Artist():
return artist(_that.artistId);case PlayContextDto_Genre():
return genre(_that.name);case PlayContextDto_Playlist():
return playlist(_that.playlistId);case PlayContextDto_Loved():
return loved();case PlayContextDto_Folder():
return folder(_that.sourceId,_that.path);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( TrackSortDto sort)?  library_,TResult? Function( PlatformInt64 albumId)?  album,TResult? Function( PlatformInt64 artistId)?  artist,TResult? Function( String name)?  genre,TResult? Function( PlatformInt64 playlistId)?  playlist,TResult? Function()?  loved,TResult? Function( PlatformInt64 sourceId,  String path)?  folder,}) {final _that = this;
switch (_that) {
case PlayContextDto_Library() when library_ != null:
return library_(_that.sort);case PlayContextDto_Album() when album != null:
return album(_that.albumId);case PlayContextDto_Artist() when artist != null:
return artist(_that.artistId);case PlayContextDto_Genre() when genre != null:
return genre(_that.name);case PlayContextDto_Playlist() when playlist != null:
return playlist(_that.playlistId);case PlayContextDto_Loved() when loved != null:
return loved();case PlayContextDto_Folder() when folder != null:
return folder(_that.sourceId,_that.path);case _:
  return null;

}
}

}

/// @nodoc


class PlayContextDto_Library extends PlayContextDto {
  const PlayContextDto_Library({required this.sort}): super._();
  

 final  TrackSortDto sort;

/// Create a copy of PlayContextDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PlayContextDto_LibraryCopyWith<PlayContextDto_Library> get copyWith => _$PlayContextDto_LibraryCopyWithImpl<PlayContextDto_Library>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is PlayContextDto_Library&&(identical(other.sort, sort) || other.sort == sort));
}


@override
int get hashCode {
    return Object.hash(runtimeType,sort);
}

@override
String toString() {
    return 'PlayContextDto.library_(sort: $sort)';
}


}

/// @nodoc
abstract mixin class $PlayContextDto_LibraryCopyWith<$Res> implements $PlayContextDtoCopyWith<$Res> {
  factory $PlayContextDto_LibraryCopyWith(PlayContextDto_Library value, $Res Function(PlayContextDto_Library) _then) = _$PlayContextDto_LibraryCopyWithImpl;
@useResult
$Res call({
 TrackSortDto sort
});




}
/// @nodoc
class _$PlayContextDto_LibraryCopyWithImpl<$Res>
    implements $PlayContextDto_LibraryCopyWith<$Res> {
  _$PlayContextDto_LibraryCopyWithImpl(this._self, this._then);

  final PlayContextDto_Library _self;
  final $Res Function(PlayContextDto_Library) _then;

/// Create a copy of PlayContextDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sort = null,}) {
  return _then(PlayContextDto_Library(
sort: null == sort ? _self.sort : sort // ignore: cast_nullable_to_non_nullable
as TrackSortDto,
  ));
}


}

/// @nodoc


class PlayContextDto_Album extends PlayContextDto {
  const PlayContextDto_Album({required this.albumId}): super._();
  

 final  PlatformInt64 albumId;

/// Create a copy of PlayContextDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PlayContextDto_AlbumCopyWith<PlayContextDto_Album> get copyWith => _$PlayContextDto_AlbumCopyWithImpl<PlayContextDto_Album>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is PlayContextDto_Album&&(identical(other.albumId, albumId) || other.albumId == albumId));
}


@override
int get hashCode {
    return Object.hash(runtimeType,albumId);
}

@override
String toString() {
    return 'PlayContextDto.album(albumId: $albumId)';
}


}

/// @nodoc
abstract mixin class $PlayContextDto_AlbumCopyWith<$Res> implements $PlayContextDtoCopyWith<$Res> {
  factory $PlayContextDto_AlbumCopyWith(PlayContextDto_Album value, $Res Function(PlayContextDto_Album) _then) = _$PlayContextDto_AlbumCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 albumId
});




}
/// @nodoc
class _$PlayContextDto_AlbumCopyWithImpl<$Res>
    implements $PlayContextDto_AlbumCopyWith<$Res> {
  _$PlayContextDto_AlbumCopyWithImpl(this._self, this._then);

  final PlayContextDto_Album _self;
  final $Res Function(PlayContextDto_Album) _then;

/// Create a copy of PlayContextDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? albumId = null,}) {
  return _then(PlayContextDto_Album(
albumId: null == albumId ? _self.albumId : albumId // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc


class PlayContextDto_Artist extends PlayContextDto {
  const PlayContextDto_Artist({required this.artistId}): super._();
  

 final  PlatformInt64 artistId;

/// Create a copy of PlayContextDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PlayContextDto_ArtistCopyWith<PlayContextDto_Artist> get copyWith => _$PlayContextDto_ArtistCopyWithImpl<PlayContextDto_Artist>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is PlayContextDto_Artist&&(identical(other.artistId, artistId) || other.artistId == artistId));
}


@override
int get hashCode {
    return Object.hash(runtimeType,artistId);
}

@override
String toString() {
    return 'PlayContextDto.artist(artistId: $artistId)';
}


}

/// @nodoc
abstract mixin class $PlayContextDto_ArtistCopyWith<$Res> implements $PlayContextDtoCopyWith<$Res> {
  factory $PlayContextDto_ArtistCopyWith(PlayContextDto_Artist value, $Res Function(PlayContextDto_Artist) _then) = _$PlayContextDto_ArtistCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 artistId
});




}
/// @nodoc
class _$PlayContextDto_ArtistCopyWithImpl<$Res>
    implements $PlayContextDto_ArtistCopyWith<$Res> {
  _$PlayContextDto_ArtistCopyWithImpl(this._self, this._then);

  final PlayContextDto_Artist _self;
  final $Res Function(PlayContextDto_Artist) _then;

/// Create a copy of PlayContextDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? artistId = null,}) {
  return _then(PlayContextDto_Artist(
artistId: null == artistId ? _self.artistId : artistId // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc


class PlayContextDto_Genre extends PlayContextDto {
  const PlayContextDto_Genre({required this.name}): super._();
  

 final  String name;

/// Create a copy of PlayContextDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PlayContextDto_GenreCopyWith<PlayContextDto_Genre> get copyWith => _$PlayContextDto_GenreCopyWithImpl<PlayContextDto_Genre>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is PlayContextDto_Genre&&(identical(other.name, name) || other.name == name));
}


@override
int get hashCode {
    return Object.hash(runtimeType,name);
}

@override
String toString() {
    return 'PlayContextDto.genre(name: $name)';
}


}

/// @nodoc
abstract mixin class $PlayContextDto_GenreCopyWith<$Res> implements $PlayContextDtoCopyWith<$Res> {
  factory $PlayContextDto_GenreCopyWith(PlayContextDto_Genre value, $Res Function(PlayContextDto_Genre) _then) = _$PlayContextDto_GenreCopyWithImpl;
@useResult
$Res call({
 String name
});




}
/// @nodoc
class _$PlayContextDto_GenreCopyWithImpl<$Res>
    implements $PlayContextDto_GenreCopyWith<$Res> {
  _$PlayContextDto_GenreCopyWithImpl(this._self, this._then);

  final PlayContextDto_Genre _self;
  final $Res Function(PlayContextDto_Genre) _then;

/// Create a copy of PlayContextDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? name = null,}) {
  return _then(PlayContextDto_Genre(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class PlayContextDto_Playlist extends PlayContextDto {
  const PlayContextDto_Playlist({required this.playlistId}): super._();
  

 final  PlatformInt64 playlistId;

/// Create a copy of PlayContextDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PlayContextDto_PlaylistCopyWith<PlayContextDto_Playlist> get copyWith => _$PlayContextDto_PlaylistCopyWithImpl<PlayContextDto_Playlist>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is PlayContextDto_Playlist&&(identical(other.playlistId, playlistId) || other.playlistId == playlistId));
}


@override
int get hashCode {
    return Object.hash(runtimeType,playlistId);
}

@override
String toString() {
    return 'PlayContextDto.playlist(playlistId: $playlistId)';
}


}

/// @nodoc
abstract mixin class $PlayContextDto_PlaylistCopyWith<$Res> implements $PlayContextDtoCopyWith<$Res> {
  factory $PlayContextDto_PlaylistCopyWith(PlayContextDto_Playlist value, $Res Function(PlayContextDto_Playlist) _then) = _$PlayContextDto_PlaylistCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 playlistId
});




}
/// @nodoc
class _$PlayContextDto_PlaylistCopyWithImpl<$Res>
    implements $PlayContextDto_PlaylistCopyWith<$Res> {
  _$PlayContextDto_PlaylistCopyWithImpl(this._self, this._then);

  final PlayContextDto_Playlist _self;
  final $Res Function(PlayContextDto_Playlist) _then;

/// Create a copy of PlayContextDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? playlistId = null,}) {
  return _then(PlayContextDto_Playlist(
playlistId: null == playlistId ? _self.playlistId : playlistId // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc


class PlayContextDto_Loved extends PlayContextDto {
  const PlayContextDto_Loved(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is PlayContextDto_Loved);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'PlayContextDto.loved()';
}


}




/// @nodoc


class PlayContextDto_Folder extends PlayContextDto {
  const PlayContextDto_Folder({required this.sourceId, required this.path}): super._();
  

 final  PlatformInt64 sourceId;
 final  String path;

/// Create a copy of PlayContextDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PlayContextDto_FolderCopyWith<PlayContextDto_Folder> get copyWith => _$PlayContextDto_FolderCopyWithImpl<PlayContextDto_Folder>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is PlayContextDto_Folder&&(identical(other.sourceId, sourceId) || other.sourceId == sourceId)&&(identical(other.path, path) || other.path == path));
}


@override
int get hashCode {
    return Object.hash(runtimeType,sourceId,path);
}

@override
String toString() {
    return 'PlayContextDto.folder(sourceId: $sourceId, path: $path)';
}


}

/// @nodoc
abstract mixin class $PlayContextDto_FolderCopyWith<$Res> implements $PlayContextDtoCopyWith<$Res> {
  factory $PlayContextDto_FolderCopyWith(PlayContextDto_Folder value, $Res Function(PlayContextDto_Folder) _then) = _$PlayContextDto_FolderCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 sourceId, String path
});




}
/// @nodoc
class _$PlayContextDto_FolderCopyWithImpl<$Res>
    implements $PlayContextDto_FolderCopyWith<$Res> {
  _$PlayContextDto_FolderCopyWithImpl(this._self, this._then);

  final PlayContextDto_Folder _self;
  final $Res Function(PlayContextDto_Folder) _then;

/// Create a copy of PlayContextDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sourceId = null,Object? path = null,}) {
  return _then(PlayContextDto_Folder(
sourceId: null == sourceId ? _self.sourceId : sourceId // ignore: cast_nullable_to_non_nullable
as PlatformInt64,path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
mixin _$RuleValueDto {

 Object get field0;



@override
bool operator ==(Object other) {
  final _this = this as RuleValueDto;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RuleValueDto&&const DeepCollectionEquality().equals(other.field0, _this.field0));
}


@override
int get hashCode {
  final _this = this as RuleValueDto;
  return Object.hash(runtimeType,const DeepCollectionEquality().hash(_this.field0));
}

@override
String toString() {
  final _this = this as RuleValueDto;
  return 'RuleValueDto(field0: ${_this.field0})';
}


}

/// @nodoc
class $RuleValueDtoCopyWith<$Res>  {
$RuleValueDtoCopyWith(RuleValueDto _, $Res Function(RuleValueDto) __);
}


/// Adds pattern-matching-related methods to [RuleValueDto].
extension RuleValueDtoPatterns on RuleValueDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( RuleValueDto_Text value)?  text,TResult Function( RuleValueDto_Number value)?  number,TResult Function( RuleValueDto_Bool value)?  bool,TResult Function( RuleValueDto_TextList value)?  textList,TResult Function( RuleValueDto_Codec value)?  codec,required TResult orElse(),}){
final _that = this;
switch (_that) {
case RuleValueDto_Text() when text != null:
return text(_that);case RuleValueDto_Number() when number != null:
return number(_that);case RuleValueDto_Bool() when bool != null:
return bool(_that);case RuleValueDto_TextList() when textList != null:
return textList(_that);case RuleValueDto_Codec() when codec != null:
return codec(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( RuleValueDto_Text value)  text,required TResult Function( RuleValueDto_Number value)  number,required TResult Function( RuleValueDto_Bool value)  bool,required TResult Function( RuleValueDto_TextList value)  textList,required TResult Function( RuleValueDto_Codec value)  codec,}){
final _that = this;
switch (_that) {
case RuleValueDto_Text():
return text(_that);case RuleValueDto_Number():
return number(_that);case RuleValueDto_Bool():
return bool(_that);case RuleValueDto_TextList():
return textList(_that);case RuleValueDto_Codec():
return codec(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( RuleValueDto_Text value)?  text,TResult? Function( RuleValueDto_Number value)?  number,TResult? Function( RuleValueDto_Bool value)?  bool,TResult? Function( RuleValueDto_TextList value)?  textList,TResult? Function( RuleValueDto_Codec value)?  codec,}){
final _that = this;
switch (_that) {
case RuleValueDto_Text() when text != null:
return text(_that);case RuleValueDto_Number() when number != null:
return number(_that);case RuleValueDto_Bool() when bool != null:
return bool(_that);case RuleValueDto_TextList() when textList != null:
return textList(_that);case RuleValueDto_Codec() when codec != null:
return codec(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String field0)?  text,TResult Function( PlatformInt64 field0)?  number,TResult Function( bool field0)?  bool,TResult Function( List<String> field0)?  textList,TResult Function( String field0)?  codec,required TResult orElse(),}) {final _that = this;
switch (_that) {
case RuleValueDto_Text() when text != null:
return text(_that.field0);case RuleValueDto_Number() when number != null:
return number(_that.field0);case RuleValueDto_Bool() when bool != null:
return bool(_that.field0);case RuleValueDto_TextList() when textList != null:
return textList(_that.field0);case RuleValueDto_Codec() when codec != null:
return codec(_that.field0);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String field0)  text,required TResult Function( PlatformInt64 field0)  number,required TResult Function( bool field0)  bool,required TResult Function( List<String> field0)  textList,required TResult Function( String field0)  codec,}) {final _that = this;
switch (_that) {
case RuleValueDto_Text():
return text(_that.field0);case RuleValueDto_Number():
return number(_that.field0);case RuleValueDto_Bool():
return bool(_that.field0);case RuleValueDto_TextList():
return textList(_that.field0);case RuleValueDto_Codec():
return codec(_that.field0);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String field0)?  text,TResult? Function( PlatformInt64 field0)?  number,TResult? Function( bool field0)?  bool,TResult? Function( List<String> field0)?  textList,TResult? Function( String field0)?  codec,}) {final _that = this;
switch (_that) {
case RuleValueDto_Text() when text != null:
return text(_that.field0);case RuleValueDto_Number() when number != null:
return number(_that.field0);case RuleValueDto_Bool() when bool != null:
return bool(_that.field0);case RuleValueDto_TextList() when textList != null:
return textList(_that.field0);case RuleValueDto_Codec() when codec != null:
return codec(_that.field0);case _:
  return null;

}
}

}

/// @nodoc


class RuleValueDto_Text extends RuleValueDto {
  const RuleValueDto_Text(this.field0): super._();
  

@override final  String field0;

/// Create a copy of RuleValueDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RuleValueDto_TextCopyWith<RuleValueDto_Text> get copyWith => _$RuleValueDto_TextCopyWithImpl<RuleValueDto_Text>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is RuleValueDto_Text&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'RuleValueDto.text(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $RuleValueDto_TextCopyWith<$Res> implements $RuleValueDtoCopyWith<$Res> {
  factory $RuleValueDto_TextCopyWith(RuleValueDto_Text value, $Res Function(RuleValueDto_Text) _then) = _$RuleValueDto_TextCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$RuleValueDto_TextCopyWithImpl<$Res>
    implements $RuleValueDto_TextCopyWith<$Res> {
  _$RuleValueDto_TextCopyWithImpl(this._self, this._then);

  final RuleValueDto_Text _self;
  final $Res Function(RuleValueDto_Text) _then;

/// Create a copy of RuleValueDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(RuleValueDto_Text(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RuleValueDto_Number extends RuleValueDto {
  const RuleValueDto_Number(this.field0): super._();
  

@override final  PlatformInt64 field0;

/// Create a copy of RuleValueDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RuleValueDto_NumberCopyWith<RuleValueDto_Number> get copyWith => _$RuleValueDto_NumberCopyWithImpl<RuleValueDto_Number>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is RuleValueDto_Number&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'RuleValueDto.number(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $RuleValueDto_NumberCopyWith<$Res> implements $RuleValueDtoCopyWith<$Res> {
  factory $RuleValueDto_NumberCopyWith(RuleValueDto_Number value, $Res Function(RuleValueDto_Number) _then) = _$RuleValueDto_NumberCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 field0
});




}
/// @nodoc
class _$RuleValueDto_NumberCopyWithImpl<$Res>
    implements $RuleValueDto_NumberCopyWith<$Res> {
  _$RuleValueDto_NumberCopyWithImpl(this._self, this._then);

  final RuleValueDto_Number _self;
  final $Res Function(RuleValueDto_Number) _then;

/// Create a copy of RuleValueDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(RuleValueDto_Number(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc


class RuleValueDto_Bool extends RuleValueDto {
  const RuleValueDto_Bool(this.field0): super._();
  

@override final  bool field0;

/// Create a copy of RuleValueDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RuleValueDto_BoolCopyWith<RuleValueDto_Bool> get copyWith => _$RuleValueDto_BoolCopyWithImpl<RuleValueDto_Bool>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is RuleValueDto_Bool&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'RuleValueDto.bool(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $RuleValueDto_BoolCopyWith<$Res> implements $RuleValueDtoCopyWith<$Res> {
  factory $RuleValueDto_BoolCopyWith(RuleValueDto_Bool value, $Res Function(RuleValueDto_Bool) _then) = _$RuleValueDto_BoolCopyWithImpl;
@useResult
$Res call({
 bool field0
});




}
/// @nodoc
class _$RuleValueDto_BoolCopyWithImpl<$Res>
    implements $RuleValueDto_BoolCopyWith<$Res> {
  _$RuleValueDto_BoolCopyWithImpl(this._self, this._then);

  final RuleValueDto_Bool _self;
  final $Res Function(RuleValueDto_Bool) _then;

/// Create a copy of RuleValueDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(RuleValueDto_Bool(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class RuleValueDto_TextList extends RuleValueDto {
  const RuleValueDto_TextList( List<String> field0): _field0 = field0,super._();
  

 final  List<String> _field0;
@override List<String> get field0 {
  if (_field0 is EqualUnmodifiableListView) return _field0;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_field0);
}


/// Create a copy of RuleValueDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RuleValueDto_TextListCopyWith<RuleValueDto_TextList> get copyWith => _$RuleValueDto_TextListCopyWithImpl<RuleValueDto_TextList>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is RuleValueDto_TextList&&const DeepCollectionEquality().equals(other.field0, _field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,const DeepCollectionEquality().hash(_field0));
}

@override
String toString() {
    return 'RuleValueDto.textList(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $RuleValueDto_TextListCopyWith<$Res> implements $RuleValueDtoCopyWith<$Res> {
  factory $RuleValueDto_TextListCopyWith(RuleValueDto_TextList value, $Res Function(RuleValueDto_TextList) _then) = _$RuleValueDto_TextListCopyWithImpl;
@useResult
$Res call({
 List<String> field0
});




}
/// @nodoc
class _$RuleValueDto_TextListCopyWithImpl<$Res>
    implements $RuleValueDto_TextListCopyWith<$Res> {
  _$RuleValueDto_TextListCopyWithImpl(this._self, this._then);

  final RuleValueDto_TextList _self;
  final $Res Function(RuleValueDto_TextList) _then;

/// Create a copy of RuleValueDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(RuleValueDto_TextList(
null == field0 ? _self._field0 : field0 // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}


}

/// @nodoc


class RuleValueDto_Codec extends RuleValueDto {
  const RuleValueDto_Codec(this.field0): super._();
  

@override final  String field0;

/// Create a copy of RuleValueDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RuleValueDto_CodecCopyWith<RuleValueDto_Codec> get copyWith => _$RuleValueDto_CodecCopyWithImpl<RuleValueDto_Codec>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is RuleValueDto_Codec&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'RuleValueDto.codec(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $RuleValueDto_CodecCopyWith<$Res> implements $RuleValueDtoCopyWith<$Res> {
  factory $RuleValueDto_CodecCopyWith(RuleValueDto_Codec value, $Res Function(RuleValueDto_Codec) _then) = _$RuleValueDto_CodecCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$RuleValueDto_CodecCopyWithImpl<$Res>
    implements $RuleValueDto_CodecCopyWith<$Res> {
  _$RuleValueDto_CodecCopyWithImpl(this._self, this._then);

  final RuleValueDto_Codec _self;
  final $Res Function(RuleValueDto_Codec) _then;

/// Create a copy of RuleValueDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(RuleValueDto_Codec(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
