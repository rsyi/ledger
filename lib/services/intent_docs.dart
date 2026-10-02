/// The parsed intent-doc trio (program / phase / strategy YAML).
///
/// Lives in its own Flutter-free file so pure services and `dart run`
/// tools can name it without importing [ProgramProvider]'s fetch stack
/// (coach_brain → Flutter). program_provider.dart re-exports it.
library;

/// Parsed trio of intent YAML files. All three fields are nullable: the
/// caller should handle missing/malformed docs gracefully.
typedef IntentDocs = ({
  Map<Object?, Object?>? program,
  Map<Object?, Object?>? phase,
  Map<Object?, Object?>? strategy,
});
