import 'package:flutter/material.dart';

/// 桌宠气泡：显示 AI 消息，可流式更新，自动隐藏。
class PetBubble extends StatelessWidget {
  const PetBubble({
    super.key,
    required this.text,
    required this.visible,
    this.typing = false,
    this.fontSize = 13,
  });

  final String text;
  final bool visible;
  final bool typing;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 250),
      child: IgnorePointer(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 300, maxHeight: 100),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xE6202540),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x557C8CFF)),
            boxShadow: const [
              BoxShadow(color: Colors.black38, blurRadius: 12, offset: Offset(0, 4)),
            ],
          ),
          // ????????????????????
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 76),
            child: SingleChildScrollView(
              reverse: false,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: Text(
                      text,
                      style: TextStyle(color: Colors.white, fontSize: fontSize, height: 1.5),
                    ),
                  ),
                  if (typing) ...[
                    const SizedBox(width: 8),
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF7C8CFF)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}