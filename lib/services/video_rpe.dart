/// Video-attach + AI-RPE support for `widget: video` fields.
library;

import 'video_attach.dart';

/// App-global holder for the video pipeline (HeartRateService.instance
/// precedent — avoids threading a rarely-used dependency through every
/// screen between home and the form). Null when the Google web client
/// id isn't configured; the form then renders the attach affordance
/// disabled with a hint.
class VideoRpeService {
  VideoRpeService({required this.flow});

  static VideoRpeService? instance;

  final VideoAttachFlow flow;
}

/// Sibling-dim convention for `widget: video` fields: the picker's
/// persistent media-item id is stored next to the URL dim in
/// `<field minus "_url">_media_id` (video_url → video_media_id). When
/// the view has no such dim the id is simply not persisted.
String mediaIdFieldFor(String videoField) {
  final base = videoField.endsWith('_url')
      ? videoField.substring(0, videoField.length - 4)
      : videoField;
  return '${base}_media_id';
}
