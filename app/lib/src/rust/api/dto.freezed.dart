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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( CoreEventDto_PlaybackChanged value)?  playbackChanged,TResult Function( CoreEventDto_PositionTick value)?  positionTick,TResult Function( CoreEventDto_QueueChanged value)?  queueChanged,TResult Function( CoreEventDto_ScanProgress value)?  scanProgress,TResult Function( CoreEventDto_ScanFinished value)?  scanFinished,TResult Function( CoreEventDto_LibraryChanged value)?  libraryChanged,TResult Function( CoreEventDto_EnrichQueueChanged value)?  enrichQueueChanged,TResult Function( CoreEventDto_SyncStatus value)?  syncStatus,TResult Function( CoreEventDto_SourceReachability value)?  sourceReachability,TResult Function( CoreEventDto_ScanFailed value)?  scanFailed,TResult Function( CoreEventDto_PlaybackOptionsChanged value)?  playbackOptionsChanged,required TResult orElse(),}){
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
return playbackOptionsChanged(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( CoreEventDto_PlaybackChanged value)  playbackChanged,required TResult Function( CoreEventDto_PositionTick value)  positionTick,required TResult Function( CoreEventDto_QueueChanged value)  queueChanged,required TResult Function( CoreEventDto_ScanProgress value)  scanProgress,required TResult Function( CoreEventDto_ScanFinished value)  scanFinished,required TResult Function( CoreEventDto_LibraryChanged value)  libraryChanged,required TResult Function( CoreEventDto_EnrichQueueChanged value)  enrichQueueChanged,required TResult Function( CoreEventDto_SyncStatus value)  syncStatus,required TResult Function( CoreEventDto_SourceReachability value)  sourceReachability,required TResult Function( CoreEventDto_ScanFailed value)  scanFailed,required TResult Function( CoreEventDto_PlaybackOptionsChanged value)  playbackOptionsChanged,}){
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
return playbackOptionsChanged(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( CoreEventDto_PlaybackChanged value)?  playbackChanged,TResult? Function( CoreEventDto_PositionTick value)?  positionTick,TResult? Function( CoreEventDto_QueueChanged value)?  queueChanged,TResult? Function( CoreEventDto_ScanProgress value)?  scanProgress,TResult? Function( CoreEventDto_ScanFinished value)?  scanFinished,TResult? Function( CoreEventDto_LibraryChanged value)?  libraryChanged,TResult? Function( CoreEventDto_EnrichQueueChanged value)?  enrichQueueChanged,TResult? Function( CoreEventDto_SyncStatus value)?  syncStatus,TResult? Function( CoreEventDto_SourceReachability value)?  sourceReachability,TResult? Function( CoreEventDto_ScanFailed value)?  scanFailed,TResult? Function( CoreEventDto_PlaybackOptionsChanged value)?  playbackOptionsChanged,}){
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
return playbackOptionsChanged(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( PlaybackStateDto state,  PlatformInt64? trackId,  BigInt positionMs,  BigInt durationMs)?  playbackChanged,TResult Function( BigInt positionMs,  BigInt bufferedMs)?  positionTick,TResult Function( int length,  int? currentIndex)?  queueChanged,TResult Function( PlatformInt64 sourceId,  ScanPhaseDto phase,  BigInt done,  BigInt? total)?  scanProgress,TResult Function( PlatformInt64 sourceId,  BigInt added,  BigInt updated,  BigInt removed)?  scanFinished,TResult Function( LibraryScopeDto scope)?  libraryChanged,TResult Function( int pending)?  enrichQueueChanged,TResult Function( SyncStateDto state)?  syncStatus,TResult Function( PlatformInt64 sourceId,  bool reachable)?  sourceReachability,TResult Function( PlatformInt64 sourceId,  ErrorKind kind,  String detail)?  scanFailed,TResult Function( RepeatModeDto repeat,  ShuffleModeDto shuffle,  double volume,  bool gapless)?  playbackOptionsChanged,required TResult orElse(),}) {final _that = this;
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
return playbackOptionsChanged(_that.repeat,_that.shuffle,_that.volume,_that.gapless);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( PlaybackStateDto state,  PlatformInt64? trackId,  BigInt positionMs,  BigInt durationMs)  playbackChanged,required TResult Function( BigInt positionMs,  BigInt bufferedMs)  positionTick,required TResult Function( int length,  int? currentIndex)  queueChanged,required TResult Function( PlatformInt64 sourceId,  ScanPhaseDto phase,  BigInt done,  BigInt? total)  scanProgress,required TResult Function( PlatformInt64 sourceId,  BigInt added,  BigInt updated,  BigInt removed)  scanFinished,required TResult Function( LibraryScopeDto scope)  libraryChanged,required TResult Function( int pending)  enrichQueueChanged,required TResult Function( SyncStateDto state)  syncStatus,required TResult Function( PlatformInt64 sourceId,  bool reachable)  sourceReachability,required TResult Function( PlatformInt64 sourceId,  ErrorKind kind,  String detail)  scanFailed,required TResult Function( RepeatModeDto repeat,  ShuffleModeDto shuffle,  double volume,  bool gapless)  playbackOptionsChanged,}) {final _that = this;
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
return playbackOptionsChanged(_that.repeat,_that.shuffle,_that.volume,_that.gapless);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( PlaybackStateDto state,  PlatformInt64? trackId,  BigInt positionMs,  BigInt durationMs)?  playbackChanged,TResult? Function( BigInt positionMs,  BigInt bufferedMs)?  positionTick,TResult? Function( int length,  int? currentIndex)?  queueChanged,TResult? Function( PlatformInt64 sourceId,  ScanPhaseDto phase,  BigInt done,  BigInt? total)?  scanProgress,TResult? Function( PlatformInt64 sourceId,  BigInt added,  BigInt updated,  BigInt removed)?  scanFinished,TResult? Function( LibraryScopeDto scope)?  libraryChanged,TResult? Function( int pending)?  enrichQueueChanged,TResult? Function( SyncStateDto state)?  syncStatus,TResult? Function( PlatformInt64 sourceId,  bool reachable)?  sourceReachability,TResult? Function( PlatformInt64 sourceId,  ErrorKind kind,  String detail)?  scanFailed,TResult? Function( RepeatModeDto repeat,  ShuffleModeDto shuffle,  double volume,  bool gapless)?  playbackOptionsChanged,}) {final _that = this;
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
return playbackOptionsChanged(_that.repeat,_that.shuffle,_that.volume,_that.gapless);case _:
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

// dart format on
