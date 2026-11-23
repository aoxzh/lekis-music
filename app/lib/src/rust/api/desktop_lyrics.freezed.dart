// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'desktop_lyrics.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$DesktopLyricsEventDto {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is DesktopLyricsEventDto);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'DesktopLyricsEventDto()';
}


}

/// @nodoc
class $DesktopLyricsEventDtoCopyWith<$Res>  {
$DesktopLyricsEventDtoCopyWith(DesktopLyricsEventDto _, $Res Function(DesktopLyricsEventDto) __);
}


/// Adds pattern-matching-related methods to [DesktopLyricsEventDto].
extension DesktopLyricsEventDtoPatterns on DesktopLyricsEventDto {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( DesktopLyricsEventDto_Closed value)?  closed,TResult Function( DesktopLyricsEventDto_VisibilityChanged value)?  visibilityChanged,TResult Function( DesktopLyricsEventDto_MenuBarClosed value)?  menuBarClosed,TResult Function( DesktopLyricsEventDto_LockChanged value)?  lockChanged,TResult Function( DesktopLyricsEventDto_Control value)?  control,TResult Function( DesktopLyricsEventDto_PlacementChanged value)?  placementChanged,required TResult orElse(),}){
final _that = this;
switch (_that) {
case DesktopLyricsEventDto_Closed() when closed != null:
return closed(_that);case DesktopLyricsEventDto_VisibilityChanged() when visibilityChanged != null:
return visibilityChanged(_that);case DesktopLyricsEventDto_MenuBarClosed() when menuBarClosed != null:
return menuBarClosed(_that);case DesktopLyricsEventDto_LockChanged() when lockChanged != null:
return lockChanged(_that);case DesktopLyricsEventDto_Control() when control != null:
return control(_that);case DesktopLyricsEventDto_PlacementChanged() when placementChanged != null:
return placementChanged(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( DesktopLyricsEventDto_Closed value)  closed,required TResult Function( DesktopLyricsEventDto_VisibilityChanged value)  visibilityChanged,required TResult Function( DesktopLyricsEventDto_MenuBarClosed value)  menuBarClosed,required TResult Function( DesktopLyricsEventDto_LockChanged value)  lockChanged,required TResult Function( DesktopLyricsEventDto_Control value)  control,required TResult Function( DesktopLyricsEventDto_PlacementChanged value)  placementChanged,}){
final _that = this;
switch (_that) {
case DesktopLyricsEventDto_Closed():
return closed(_that);case DesktopLyricsEventDto_VisibilityChanged():
return visibilityChanged(_that);case DesktopLyricsEventDto_MenuBarClosed():
return menuBarClosed(_that);case DesktopLyricsEventDto_LockChanged():
return lockChanged(_that);case DesktopLyricsEventDto_Control():
return control(_that);case DesktopLyricsEventDto_PlacementChanged():
return placementChanged(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( DesktopLyricsEventDto_Closed value)?  closed,TResult? Function( DesktopLyricsEventDto_VisibilityChanged value)?  visibilityChanged,TResult? Function( DesktopLyricsEventDto_MenuBarClosed value)?  menuBarClosed,TResult? Function( DesktopLyricsEventDto_LockChanged value)?  lockChanged,TResult? Function( DesktopLyricsEventDto_Control value)?  control,TResult? Function( DesktopLyricsEventDto_PlacementChanged value)?  placementChanged,}){
final _that = this;
switch (_that) {
case DesktopLyricsEventDto_Closed() when closed != null:
return closed(_that);case DesktopLyricsEventDto_VisibilityChanged() when visibilityChanged != null:
return visibilityChanged(_that);case DesktopLyricsEventDto_MenuBarClosed() when menuBarClosed != null:
return menuBarClosed(_that);case DesktopLyricsEventDto_LockChanged() when lockChanged != null:
return lockChanged(_that);case DesktopLyricsEventDto_Control() when control != null:
return control(_that);case DesktopLyricsEventDto_PlacementChanged() when placementChanged != null:
return placementChanged(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  closed,TResult Function( bool visible)?  visibilityChanged,TResult Function()?  menuBarClosed,TResult Function( bool locked)?  lockChanged,TResult Function( DesktopLyricsControlDto action)?  control,TResult Function( String json)?  placementChanged,required TResult orElse(),}) {final _that = this;
switch (_that) {
case DesktopLyricsEventDto_Closed() when closed != null:
return closed();case DesktopLyricsEventDto_VisibilityChanged() when visibilityChanged != null:
return visibilityChanged(_that.visible);case DesktopLyricsEventDto_MenuBarClosed() when menuBarClosed != null:
return menuBarClosed();case DesktopLyricsEventDto_LockChanged() when lockChanged != null:
return lockChanged(_that.locked);case DesktopLyricsEventDto_Control() when control != null:
return control(_that.action);case DesktopLyricsEventDto_PlacementChanged() when placementChanged != null:
return placementChanged(_that.json);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  closed,required TResult Function( bool visible)  visibilityChanged,required TResult Function()  menuBarClosed,required TResult Function( bool locked)  lockChanged,required TResult Function( DesktopLyricsControlDto action)  control,required TResult Function( String json)  placementChanged,}) {final _that = this;
switch (_that) {
case DesktopLyricsEventDto_Closed():
return closed();case DesktopLyricsEventDto_VisibilityChanged():
return visibilityChanged(_that.visible);case DesktopLyricsEventDto_MenuBarClosed():
return menuBarClosed();case DesktopLyricsEventDto_LockChanged():
return lockChanged(_that.locked);case DesktopLyricsEventDto_Control():
return control(_that.action);case DesktopLyricsEventDto_PlacementChanged():
return placementChanged(_that.json);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  closed,TResult? Function( bool visible)?  visibilityChanged,TResult? Function()?  menuBarClosed,TResult? Function( bool locked)?  lockChanged,TResult? Function( DesktopLyricsControlDto action)?  control,TResult? Function( String json)?  placementChanged,}) {final _that = this;
switch (_that) {
case DesktopLyricsEventDto_Closed() when closed != null:
return closed();case DesktopLyricsEventDto_VisibilityChanged() when visibilityChanged != null:
return visibilityChanged(_that.visible);case DesktopLyricsEventDto_MenuBarClosed() when menuBarClosed != null:
return menuBarClosed();case DesktopLyricsEventDto_LockChanged() when lockChanged != null:
return lockChanged(_that.locked);case DesktopLyricsEventDto_Control() when control != null:
return control(_that.action);case DesktopLyricsEventDto_PlacementChanged() when placementChanged != null:
return placementChanged(_that.json);case _:
  return null;

}
}

}

/// @nodoc


class DesktopLyricsEventDto_Closed extends DesktopLyricsEventDto {
  const DesktopLyricsEventDto_Closed(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is DesktopLyricsEventDto_Closed);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'DesktopLyricsEventDto.closed()';
}


}




/// @nodoc


class DesktopLyricsEventDto_VisibilityChanged extends DesktopLyricsEventDto {
  const DesktopLyricsEventDto_VisibilityChanged({required this.visible}): super._();


 final  bool visible;

/// Create a copy of DesktopLyricsEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DesktopLyricsEventDto_VisibilityChangedCopyWith<DesktopLyricsEventDto_VisibilityChanged> get copyWith => _$DesktopLyricsEventDto_VisibilityChangedCopyWithImpl<DesktopLyricsEventDto_VisibilityChanged>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is DesktopLyricsEventDto_VisibilityChanged&&(identical(other.visible, visible) || other.visible == visible));
}


@override
int get hashCode {
    return Object.hash(runtimeType,visible);
}

@override
String toString() {
    return 'DesktopLyricsEventDto.visibilityChanged(visible: $visible)';
}


}

/// @nodoc
abstract mixin class $DesktopLyricsEventDto_VisibilityChangedCopyWith<$Res> implements $DesktopLyricsEventDtoCopyWith<$Res> {
  factory $DesktopLyricsEventDto_VisibilityChangedCopyWith(DesktopLyricsEventDto_VisibilityChanged value, $Res Function(DesktopLyricsEventDto_VisibilityChanged) _then) = _$DesktopLyricsEventDto_VisibilityChangedCopyWithImpl;
@useResult
$Res call({
 bool visible
});




}
/// @nodoc
class _$DesktopLyricsEventDto_VisibilityChangedCopyWithImpl<$Res>
    implements $DesktopLyricsEventDto_VisibilityChangedCopyWith<$Res> {
  _$DesktopLyricsEventDto_VisibilityChangedCopyWithImpl(this._self, this._then);

  final DesktopLyricsEventDto_VisibilityChanged _self;
  final $Res Function(DesktopLyricsEventDto_VisibilityChanged) _then;

/// Create a copy of DesktopLyricsEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? visible = null,}) {
  return _then(DesktopLyricsEventDto_VisibilityChanged(
visible: null == visible ? _self.visible : visible // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class DesktopLyricsEventDto_MenuBarClosed extends DesktopLyricsEventDto {
  const DesktopLyricsEventDto_MenuBarClosed(): super._();







@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is DesktopLyricsEventDto_MenuBarClosed);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'DesktopLyricsEventDto.menuBarClosed()';
}


}




/// @nodoc


class DesktopLyricsEventDto_LockChanged extends DesktopLyricsEventDto {
  const DesktopLyricsEventDto_LockChanged({required this.locked}): super._();
  

 final  bool locked;

/// Create a copy of DesktopLyricsEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DesktopLyricsEventDto_LockChangedCopyWith<DesktopLyricsEventDto_LockChanged> get copyWith => _$DesktopLyricsEventDto_LockChangedCopyWithImpl<DesktopLyricsEventDto_LockChanged>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is DesktopLyricsEventDto_LockChanged&&(identical(other.locked, locked) || other.locked == locked));
}


@override
int get hashCode {
    return Object.hash(runtimeType,locked);
}

@override
String toString() {
    return 'DesktopLyricsEventDto.lockChanged(locked: $locked)';
}


}

/// @nodoc
abstract mixin class $DesktopLyricsEventDto_LockChangedCopyWith<$Res> implements $DesktopLyricsEventDtoCopyWith<$Res> {
  factory $DesktopLyricsEventDto_LockChangedCopyWith(DesktopLyricsEventDto_LockChanged value, $Res Function(DesktopLyricsEventDto_LockChanged) _then) = _$DesktopLyricsEventDto_LockChangedCopyWithImpl;
@useResult
$Res call({
 bool locked
});




}
/// @nodoc
class _$DesktopLyricsEventDto_LockChangedCopyWithImpl<$Res>
    implements $DesktopLyricsEventDto_LockChangedCopyWith<$Res> {
  _$DesktopLyricsEventDto_LockChangedCopyWithImpl(this._self, this._then);

  final DesktopLyricsEventDto_LockChanged _self;
  final $Res Function(DesktopLyricsEventDto_LockChanged) _then;

/// Create a copy of DesktopLyricsEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? locked = null,}) {
  return _then(DesktopLyricsEventDto_LockChanged(
locked: null == locked ? _self.locked : locked // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class DesktopLyricsEventDto_Control extends DesktopLyricsEventDto {
  const DesktopLyricsEventDto_Control({required this.action}): super._();
  

 final  DesktopLyricsControlDto action;

/// Create a copy of DesktopLyricsEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DesktopLyricsEventDto_ControlCopyWith<DesktopLyricsEventDto_Control> get copyWith => _$DesktopLyricsEventDto_ControlCopyWithImpl<DesktopLyricsEventDto_Control>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is DesktopLyricsEventDto_Control&&(identical(other.action, action) || other.action == action));
}


@override
int get hashCode {
    return Object.hash(runtimeType,action);
}

@override
String toString() {
    return 'DesktopLyricsEventDto.control(action: $action)';
}


}

/// @nodoc
abstract mixin class $DesktopLyricsEventDto_ControlCopyWith<$Res> implements $DesktopLyricsEventDtoCopyWith<$Res> {
  factory $DesktopLyricsEventDto_ControlCopyWith(DesktopLyricsEventDto_Control value, $Res Function(DesktopLyricsEventDto_Control) _then) = _$DesktopLyricsEventDto_ControlCopyWithImpl;
@useResult
$Res call({
 DesktopLyricsControlDto action
});




}
/// @nodoc
class _$DesktopLyricsEventDto_ControlCopyWithImpl<$Res>
    implements $DesktopLyricsEventDto_ControlCopyWith<$Res> {
  _$DesktopLyricsEventDto_ControlCopyWithImpl(this._self, this._then);

  final DesktopLyricsEventDto_Control _self;
  final $Res Function(DesktopLyricsEventDto_Control) _then;

/// Create a copy of DesktopLyricsEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? action = null,}) {
  return _then(DesktopLyricsEventDto_Control(
action: null == action ? _self.action : action // ignore: cast_nullable_to_non_nullable
as DesktopLyricsControlDto,
  ));
}


}

/// @nodoc


class DesktopLyricsEventDto_PlacementChanged extends DesktopLyricsEventDto {
  const DesktopLyricsEventDto_PlacementChanged({required this.json}): super._();
  

 final  String json;

/// Create a copy of DesktopLyricsEventDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DesktopLyricsEventDto_PlacementChangedCopyWith<DesktopLyricsEventDto_PlacementChanged> get copyWith => _$DesktopLyricsEventDto_PlacementChangedCopyWithImpl<DesktopLyricsEventDto_PlacementChanged>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is DesktopLyricsEventDto_PlacementChanged&&(identical(other.json, json) || other.json == json));
}


@override
int get hashCode {
    return Object.hash(runtimeType,json);
}

@override
String toString() {
    return 'DesktopLyricsEventDto.placementChanged(json: $json)';
}


}

/// @nodoc
abstract mixin class $DesktopLyricsEventDto_PlacementChangedCopyWith<$Res> implements $DesktopLyricsEventDtoCopyWith<$Res> {
  factory $DesktopLyricsEventDto_PlacementChangedCopyWith(DesktopLyricsEventDto_PlacementChanged value, $Res Function(DesktopLyricsEventDto_PlacementChanged) _then) = _$DesktopLyricsEventDto_PlacementChangedCopyWithImpl;
@useResult
$Res call({
 String json
});




}
/// @nodoc
class _$DesktopLyricsEventDto_PlacementChangedCopyWithImpl<$Res>
    implements $DesktopLyricsEventDto_PlacementChangedCopyWith<$Res> {
  _$DesktopLyricsEventDto_PlacementChangedCopyWithImpl(this._self, this._then);

  final DesktopLyricsEventDto_PlacementChanged _self;
  final $Res Function(DesktopLyricsEventDto_PlacementChanged) _then;

/// Create a copy of DesktopLyricsEventDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? json = null,}) {
  return _then(DesktopLyricsEventDto_PlacementChanged(
json: null == json ? _self.json : json // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
