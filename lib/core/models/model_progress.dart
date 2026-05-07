enum ModelPhase { downloading, loading }

class ModelProgress {
  final double value;
  final ModelPhase phase;
  const ModelProgress(this.value, this.phase);
}