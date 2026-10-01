/// Thread id rows with a blank `thread` dimension belong to (the
/// pre-threads history). Lives in the service layer so pure helpers
/// (today_thread.dart) can resolve a row's thread without importing UI.
const kCoachThreadGeneral = 'general';
