/// Video-attach + AI-RPE support for `widget: video` fields.
///
/// Phase A ships the schema convention only; the picker flow and the
/// Claude estimation pipeline land on top of this file.
library;

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
