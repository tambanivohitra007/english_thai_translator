import 'package:flutter/material.dart';
import '../models/enums.dart';

class MicButton extends StatelessWidget {
  final TranslationDirection direction;
  final String label;
  final IconData icon;
  final bool isActive;
  final VoidCallback onTap;

  const MicButton({
    super.key,
    required this.direction,
    required this.label,
    required this.icon,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            width: isActive ? 80 : 70,
            height: isActive ? 80 : 70,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: isActive
                  ? const LinearGradient(
                      colors: [Color(0xFFFF512F), Color(0xFFDD2476)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : LinearGradient(
                      colors: [
                        Colors.white.withAlpha(20),
                        Colors.white.withAlpha(5),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
              border: Border.all(
                color: isActive
                    ? Colors.transparent
                    : Colors.white.withAlpha(30),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: isActive
                      ? const Color(0xFFDD2476).withAlpha(100)
                      : Colors.transparent,
                  blurRadius: isActive ? 20 : 0,
                  spreadRadius: isActive ? 2 : 0,
                ),
              ],
            ),
            child: Icon(
              isActive ? Icons.stop_rounded : icon,
              color: Colors.white,
              size: 32,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w600,
              color: isActive ? Colors.white : Colors.white.withAlpha(150),
            ),
          ),
        ],
      ),
    );
  }
}
