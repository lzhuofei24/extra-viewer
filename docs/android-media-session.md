# Android music media session

The existing media_kit player remains the only audio engine. The audio_service
handler observes both controller changes and native player events, publishes
MediaItem / queue / PlaybackState, and forwards system commands to that same
controller. It does not create a second player.

Implementation references (independently adapted, not vendored source):

- Android Media3 session demo:
  https://github.com/androidx/media/blob/release/demos/session_service/src/main/java/androidx/media3/demo/session/DemoPlaybackService.kt
- audio_service maintainer Android 13 example:
  https://github.com/ryanheise/audio_service/blob/minor/audio_service/example/lib/example_android13.dart
- Harmonoid media-session state synchronization:
  https://github.com/harmonoid/harmonoid/blob/master/lib/core/media_player/mixin/audio_service_mixin.dart

Playing, buffering, completion, duration and rate changes publish immediately.
Ordinary position updates are throttled to one-second differences. Commands
also republish after completion. Old player subscriptions are detached when
the controller or native player changes.

Media-session initialization is independent of audio-focus configuration.
Platform publication errors go to `audio_service_platform_error` in the
internal diagnostic log. The dynamically resolved notification icon and plugin
action icons are retained through Android resource shrinking by `res/raw/keep.xml`.

Pausing retains the foreground service to support background resume. Removing
the app task stops the audio and clears the notification. An interruption or
headphone removal pauses playback; resumption requires user action.

Media-session notifications are exempt from Android 13 POST_NOTIFICATIONS:
https://developer.android.com/develop/ui/views/notifications/notification-permission#media-sessions
Permission requests are therefore not a substitute for session publication.

Automated Dart tests validate state and command routing, not OEM system UI.
Lock-screen controls, Samsung notification rendering and background playback
still require an authorized physical device for acceptance.
