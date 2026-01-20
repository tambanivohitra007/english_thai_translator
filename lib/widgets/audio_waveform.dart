import 'package:flutter/material.dart';

class AudioWaveform extends StatelessWidget {
  final double amplitude; // in dB, typically -160 to 0

  const AudioWaveform({super.key, required this.amplitude});

  @override
  Widget build(BuildContext context) {
    // Normalize dB to 0.0 - 1.0
    double normalized = (amplitude + 60) / 60;
    if (normalized < 0) normalized = 0;
    if (normalized > 1) normalized = 1;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(5, (index) {
        double heightFactor = normalized;
        if (index == 0 || index == 4) heightFactor *= 0.6;
        if (index == 1 || index == 3) heightFactor *= 0.8;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: 8,
          height: 10 + (40 * heightFactor), // Base height 10, max +40
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(200),
            borderRadius: BorderRadius.circular(50),
            boxShadow: [
              BoxShadow(
                color: Colors.white.withAlpha(100),
                blurRadius: (10 * heightFactor).clamp(0.0, double.infinity),
                spreadRadius: (2 * heightFactor).clamp(0.0, double.infinity),
              ),
            ],
          ),
        );
      }),
    );
  }
}
