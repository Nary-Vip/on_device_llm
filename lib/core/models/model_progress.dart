enum ModelPhase { downloading, loading }

class ModelProgress {
  final double value;
  final ModelPhase phase;
  final int downloadedBytes;
  final int totalBytes;
  const ModelProgress(
    this.value,
    this.phase, {
    this.downloadedBytes = 0,
    this.totalBytes = 0,
  });
}
