import 'package:flutter/material.dart';

/// Chat reply bubble. Long replies remain readable and streaming replies keep
/// the newest text visible without hiding the bubble mid-request.
class PetBubble extends StatefulWidget {
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
  State<PetBubble> createState() => _PetBubbleState();
}

class _PetBubbleState extends State<PetBubble> {
  final ScrollController _scroll = ScrollController();
  bool _followTail = true;

  @override
  void didUpdateWidget(covariant PetBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_followTail || !_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final height = MediaQuery.sizeOf(context).height;
    return AnimatedOpacity(
      opacity: widget.visible ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: 40,
          maxWidth: width.clamp(180.0, 340.0) - 24,
          maxHeight: (height * .38).clamp(100.0, 240.0),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xE6202540),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x557C8CFF)),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is UserScrollNotification) {
                _followTail =
                    notification.metrics.pixels >=
                    notification.metrics.maxScrollExtent - 24;
              }
              return false;
            },
            child: Scrollbar(
              controller: _scroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _scroll,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        widget.text,
                        softWrap: true,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: widget.fontSize,
                          height: 1.5,
                        ),
                      ),
                    ),
                    if (widget.typing) ...[
                      const SizedBox(width: 8),
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF7C8CFF),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
