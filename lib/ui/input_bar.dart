import 'package:flutter/material.dart';

/// 桌宠输入栏：底部毛玻璃输入框。
class PetInputBar extends StatefulWidget {
  const PetInputBar({
    super.key,
    required this.onSend,
    this.enabled = true,
    this.autofocus = false,
  });

  final Future<void> Function(String text) onSend;
  final bool enabled;
  final bool autofocus;

  @override
  State<PetInputBar> createState() => _PetInputBarState();
}

class _PetInputBarState extends State<PetInputBar> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    _controller.clear();
    try {
      await widget.onSend(text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xCC1C2138),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0x557C8CFF)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              autofocus: widget.autofocus,
              enabled: widget.enabled && !_busy,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                hintText: '和牧濑红莉栖说点什么…',
                hintStyle: TextStyle(color: Color(0x8899A3C7), fontSize: 13),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
              onSubmitted: (_) => _send(),
              onTapOutside: (_) => FocusScope.of(context).unfocus(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: (widget.enabled && !_busy) ? _send : null,
            icon: const Icon(
              Icons.send_rounded,
              size: 18,
              color: Color(0xFF7C8CFF),
            ),
            tooltip: '发送',
          ),
        ],
      ),
    );
  }
}
