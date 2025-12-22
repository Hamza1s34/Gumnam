import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'dart:convert';
import 'dart:io';

/// Common reaction emojis for quick picker
const List<String> kCommonReactions = [
  '\u{1F44D}', // 👍
  '\u{2764}\u{FE0F}', // ❤️
  '\u{1F602}', // 😂
  '\u{1F62E}', // 😮
  '\u{1F622}', // 😢
  '\u{1F64F}', // 🙏
];

/// Manager class for handling message reactions with persistence
/// Only allows ONE reaction per message
class MessageReactionsManager {
  static final MessageReactionsManager _instance = MessageReactionsManager._internal();
  factory MessageReactionsManager() => _instance;
  MessageReactionsManager._internal();

  // Map of messageId -> single reaction emoji (only one allowed)
  final Map<String, String> _reactions = {};
  bool _isLoaded = false;

  Future<void> load() async {
    if (_isLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString('message_reactions_v2');
      if (data != null) {
        final Map<String, dynamic> decoded = jsonDecode(data);
        _reactions.clear();
        decoded.forEach((key, value) {
          _reactions[key] = value.toString();
        });
      }
      _isLoaded = true;
    } catch (e) {
      debugPrint('Error loading reactions: $e');
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('message_reactions_v2', jsonEncode(_reactions));
    } catch (e) {
      debugPrint('Error saving reactions: $e');
    }
  }

  String? getReaction(String messageId) {
    return _reactions[messageId];
  }

  Future<void> setReaction(String messageId, String emoji) async {
    // If same emoji, remove it (toggle off)
    if (_reactions[messageId] == emoji) {
      _reactions.remove(messageId);
    } else {
      // Replace with new emoji
      _reactions[messageId] = emoji;
    }
    await _save();
  }

  Future<void> removeReaction(String messageId) async {
    _reactions.remove(messageId);
    await _save();
  }

  bool hasReaction(String messageId) {
    return _reactions.containsKey(messageId);
  }
}

/// Quick reaction picker with 6 common emojis + more button
class QuickReactionPicker extends StatelessWidget {
  final void Function(String emoji) onReactionSelected;
  final VoidCallback onMorePressed;
  final String? currentReaction;

  const QuickReactionPicker({
    super.key,
    required this.onReactionSelected,
    required this.onMorePressed,
    this.currentReaction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...kCommonReactions.map((emoji) => _buildEmojiButton(emoji)),
          const SizedBox(width: 4),
          _buildMoreButton(),
        ],
      ),
    );
  }

  Widget _buildEmojiButton(String emoji) {
    final isSelected = currentReaction == emoji;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onReactionSelected(emoji),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: isSelected
              ? BoxDecoration(
                  color: const Color(0xFF7B61FF).withOpacity(0.3),
                  shape: BoxShape.circle,
                )
              : null,
          child: Text(
            emoji,
            style: const TextStyle(fontSize: 24),
          ),
        ),
      ),
    );
  }

  Widget _buildMoreButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onMorePressed,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.grey.withOpacity(0.2),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.add,
            color: Colors.white,
            size: 24,
          ),
        ),
      ),
    );
  }
}

/// Full emoji picker using emoji_picker_flutter library
class FullEmojiPickerWidget extends StatelessWidget {
  final void Function(String emoji) onEmojiSelected;

  const FullEmojiPickerWidget({
    super.key,
    required this.onEmojiSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 350,
      height: 400,
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: EmojiPicker(
          onEmojiSelected: (category, emoji) {
            onEmojiSelected(emoji.emoji);
          },
          config: Config(
            height: 400,
            checkPlatformCompatibility: true,
            emojiViewConfig: EmojiViewConfig(
              emojiSizeMax: 28 * (Platform.isIOS ? 1.30 : 1.0),
              columns: 8,
              verticalSpacing: 0,
              horizontalSpacing: 0,
              backgroundColor: const Color(0xFF1E1E1E),
              recentsLimit: 28,
              buttonMode: ButtonMode.CUPERTINO,
            ),
            skinToneConfig: const SkinToneConfig(
              enabled: true,
            ),
            categoryViewConfig: const CategoryViewConfig(
              initCategory: Category.SMILEYS,
              backgroundColor: Color(0xFF1E1E1E),
              indicatorColor: Color(0xFF7B61FF),
              iconColor: Colors.grey,
              iconColorSelected: Color(0xFF7B61FF),
              backspaceColor: Color(0xFF7B61FF),
              dividerColor: Color(0xFF1E1E1E),
              tabBarHeight: 46,
            ),
            bottomActionBarConfig: const BottomActionBarConfig(
              backgroundColor: Color(0xFF1E1E1E),
              buttonColor: Color(0xFF1E1E1E),
              buttonIconColor: Colors.grey,
              showBackspaceButton: false,
              showSearchViewButton: true,
            ),
            searchViewConfig: const SearchViewConfig(
              backgroundColor: Color(0xFF1E1E1E),
              buttonIconColor: Colors.grey,
              hintTextStyle: TextStyle(color: Colors.grey, fontSize: 16),
              inputTextStyle: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ),
      ),
    );
  }
}

/// Widget to display a single reaction outside the message bubble
class MessageReactionDisplay extends StatelessWidget {
  final String? reaction;
  final bool isMe;
  final VoidCallback? onTap;

  const MessageReactionDisplay({
    super.key,
    required this.reaction,
    required this.isMe,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (reaction == null || reaction!.isEmpty) return const SizedBox.shrink();

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(
          left: isMe ? 0 : 8,
          right: isMe ? 8 : 0,
          top: 2,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF3A3A3A),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.white.withOpacity(0.15),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Text(
                reaction!,
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Dialog to show the reaction picker
class ReactionPickerDialog extends StatefulWidget {
  final void Function(String emoji) onReactionSelected;
  final String? currentReaction;

  const ReactionPickerDialog({
    super.key,
    required this.onReactionSelected,
    this.currentReaction,
  });

  @override
  State<ReactionPickerDialog> createState() => _ReactionPickerDialogState();
}

class _ReactionPickerDialogState extends State<ReactionPickerDialog> {
  bool _showFullPicker = false;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: _showFullPicker
          ? FullEmojiPickerWidget(
              onEmojiSelected: (emoji) {
                widget.onReactionSelected(emoji);
                Navigator.pop(context);
              },
            )
          : QuickReactionPicker(
              currentReaction: widget.currentReaction,
              onReactionSelected: (emoji) {
                widget.onReactionSelected(emoji);
                Navigator.pop(context);
              },
              onMorePressed: () {
                setState(() {
                  _showFullPicker = true;
                });
              },
            ),
    );
  }
}

/// Helper function to show the reaction picker
Future<void> showReactionPicker(
  BuildContext context, {
  required void Function(String emoji) onReactionSelected,
  String? currentReaction,
}) async {
  await showDialog(
    context: context,
    barrierColor: Colors.black.withOpacity(0.3),
    builder: (context) => ReactionPickerDialog(
      onReactionSelected: onReactionSelected,
      currentReaction: currentReaction,
    ),
  );
}
