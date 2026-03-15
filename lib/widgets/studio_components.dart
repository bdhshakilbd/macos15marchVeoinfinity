import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import '../utils/theme_provider.dart';

/// Premium Color Scheme based on the reference design
class StudioColors {
  static const Color primary = Color(0xFF1E40AF); // Premium Royal Blue
  static const Color primaryHover = Color(0xFF1E3A8A);
  static const Color backgroundLight = Color(0xFFF7F9FC); // Ivory
  static const Color backgroundDark = Color(0xFF0F172A); // Dark Slate
  static const Color cardLight = Colors.white;
  static const Color cardDark = Color(0xFF1E293B);
  static const Color borderLight = Color(0xFFE2E8F0);
  static const Color borderDark = Color(0xFF334155);
  static const Color textPrimary = Color(0xFF1E293B);
  static const Color textSecondary = Color(0xFF64748B);
  static const Color success = Color(0xFF10B981);
  static const Color danger = Color(0xFFEF4444);
  static const Color warning = Color(0xFFF59E0B);
}

/// Character panel item widget
class CharacterListItem extends StatelessWidget {
  final String name;
  final String? imagePath;
  final bool isActive;
  final VoidCallback? onTap;
  final VoidCallback? onMore;

  const CharacterListItem({
    super.key,
    required this.name,
    this.imagePath,
    this.isActive = false,
    this.onTap,
    this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? StudioColors.primary.withOpacity(0.3) : const Color(0xFFE2E8F0),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                // Avatar
                Stack(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: StudioColors.primary, width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: StudioColors.primary.withOpacity(0.2),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: imagePath != null && File(imagePath!).existsSync()
                            ? Image.file(File(imagePath!), fit: BoxFit.cover)
                            : Container(
                                color: StudioColors.primary.withOpacity(0.1),
                                child: Icon(Icons.person, color: StudioColors.primary.withOpacity(0.5)),
                              ),
                      ),
                    ),
                    if (isActive)
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: StudioColors.success,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                // Info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: StudioColors.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isActive 
                              ? const Color(0xFFEFF6FF)
                              : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          isActive ? 'Active' : 'Idle',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isActive 
                                ? StudioColors.primary
                                : StudioColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // More button
                IconButton(
                  icon: const Icon(Icons.more_vert, size: 18),
                  color: StudioColors.textSecondary,
                  onPressed: onMore,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Generated image card widget
class GeneratedImageCard extends StatelessWidget {
  final String imagePath;
  final String? prompt;
  final String? sceneNumber;
  final String? duration;
  final Function(String)? onRegenerate;
  final VoidCallback? onView;
  final VoidCallback? onDelete;
  final VoidCallback? onTap;

  const GeneratedImageCard({
    super.key,
    required this.imagePath,
    this.prompt,
    this.sceneNumber,
    this.duration,
    this.onRegenerate,
    this.onView,
    this.onDelete,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            // Main Image
            AspectRatio(
              aspectRatio: 16 / 9,
              child: InkWell(
                onTap: onTap,
                child: File(imagePath).existsSync()
                    ? Image.file(File(imagePath), fit: BoxFit.cover)
                    : Container(
                        color: const Color(0xFFF1F5F9),
                        child: const Icon(Icons.image, size: 48, color: Color(0xFFCBD5E1)),
                      ),
              ),
            ),
            
            // Premium Scene Number Overlay
            if (sceneNumber != null)
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF1E40AF), Color(0xFF7C3AED)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    'Scene $sceneNumber',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),

            // Top-Right Action Buttons
            Positioned(
              top: 8,
              right: 8,
              child: Row(
                children: [
                   _buildIconButton(Icons.refresh, () => _showPromptPopup(context)),
                   const SizedBox(width: 4),
                   _buildIconButton(Icons.delete_outline, onDelete, color: Colors.red.shade400),
                ],
              ),
            ),

            // Subtle Status Indicator (bottom-right)
            Positioned(
              bottom: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  duration ?? 'Done',
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPromptPopup(BuildContext context) {
    final TextEditingController promptController = TextEditingController(text: prompt);
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.edit_note, color: Color(0xFF1E40AF)),
            const SizedBox(width: 8),
            Text('Edit & Regenerate Scene $sceneNumber', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('PROMPT (EDITABLE):', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: TextField(
                controller: promptController,
                maxLines: 5,
                style: const TextStyle(fontSize: 15, height: 1.5, color: Color(0xFF334155)),
                decoration: InputDecoration(
                  hintText: 'Enter scene prompt...',
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.all(12),
                  hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.info_outline, size: 14, color: Color(0xFF64748B)),
                const SizedBox(width: 4),
                Text(
                  'Original Ref: ${duration ?? '0.0s'}',
                  style: const TextStyle(fontSize: 15, color: Color(0xFF64748B)),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF64748B), fontSize: 14)),
          ),
          ElevatedButton.icon(
            onPressed: () {
              final newPrompt = promptController.text.trim();
              if (newPrompt.isNotEmpty) {
                Navigator.pop(context);
                onRegenerate?.call(newPrompt);
              }
            },
            icon: const Icon(Icons.auto_awesome, size: 18),
            label: const Text('REGENERATE', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1E40AF),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIconButton(IconData icon, VoidCallback? onPressed, {Color color = Colors.white}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: IconButton(
        icon: Icon(icon, size: 14, color: color),
        onPressed: onPressed,
        padding: const EdgeInsets.all(6),
        constraints: const BoxConstraints(),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// Premium toolbar button - Light font style matching reference
class ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool isPrimary;

  const ToolbarButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    if (isPrimary) {
      return Container(
        decoration: BoxDecoration(
          color: StudioColors.primary,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 14, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // Light outlined button matching reference design - no bold/uppercase
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE2E8F0)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: const Color(0xFF64748B)),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF374151),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact number input
class CompactNumberInput extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final double width;

  const CompactNumberInput({
    super.key,
    required this.label,
    required this.controller,
    this.width = 40,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: StudioColors.textSecondary,
          ),
        ),
        const SizedBox(width: 6),
        Container(
          width: width,
          height: 28,
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFE2E8F0)),
            borderRadius: BorderRadius.circular(6),
            color: Colors.white,
          ),
          child: TextField(
            controller: controller,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              isDense: true,
            ),
            keyboardType: TextInputType.number,
          ),
        ),
      ],
    );
  }
}

/// Terminal/Log panel widget
class TerminalPanel extends StatefulWidget {
  final List<LogEntry> entries;
  final ScrollController? scrollController;
  final VoidCallback? onClose;
  final VoidCallback? onClear;

  const TerminalPanel({
    super.key,
    required this.entries,
    this.scrollController,
    this.onClose,
    this.onClear,
  });

  @override
  State<TerminalPanel> createState() => _TerminalPanelState();
}

class _TerminalPanelState extends State<TerminalPanel> {
  bool _isFullscreen = false;
  int _lastEntryCount = 0;

  @override
  void didUpdateWidget(covariant TerminalPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Auto-scroll to bottom when new entries are added
    if (widget.entries.length != _lastEntryCount) {
      _lastEntryCount = widget.entries.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final controller = widget.scrollController;
        if (controller != null && controller.hasClients) {
          controller.animateTo(
            controller.position.maxScrollExtent,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF000000),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF222222)),
      ),
      child: Column(
        children: [
          // Header
          Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF1A1A1A),
              borderRadius: BorderRadius.vertical(top: Radius.circular(7)),
              border: Border(bottom: BorderSide(color: Color(0xFF333333))),
            ),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 12, color: Color(0xFF94A3B8)),
                const SizedBox(width: 6),
                const Text(
                  'Logs',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFE2E8F0),
                  ),
                ),
                const Spacer(),
                // Clear all logs
                InkWell(
                  onTap: widget.onClear,
                  borderRadius: BorderRadius.circular(4),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.delete_sweep, size: 12, color: Color(0xFF94A3B8)),
                        SizedBox(width: 3),
                        Text('Clear All', style: TextStyle(fontSize: 9, color: Color(0xFF94A3B8))),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Close panel
                InkWell(
                  onTap: widget.onClose,
                  borderRadius: BorderRadius.circular(4),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.close, size: 12, color: Color(0xFF94A3B8)),
                  ),
                ),
              ],
            ),
          ),
          // Log entries
          Expanded(
            flex: _isFullscreen ? 100 : 1,
            child: Focus(
              autofocus: false,
              onKey: (node, event) {
                final controller = widget.scrollController;
                if (controller != null && event is RawKeyDownEvent) {
                  const double scrollAmount = 40.0;
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                    final newOffset = (controller.offset - scrollAmount).clamp(0.0, controller.position.maxScrollExtent);
                    controller.jumpTo(newOffset);
                    return KeyEventResult.handled;
                  } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                    final newOffset = (controller.offset + scrollAmount).clamp(0.0, controller.position.maxScrollExtent);
                    controller.jumpTo(newOffset);
                    return KeyEventResult.handled;
                  } else if (event.logicalKey == LogicalKeyboardKey.pageUp) {
                    final newOffset = (controller.offset - 200).clamp(0.0, controller.position.maxScrollExtent);
                    controller.jumpTo(newOffset);
                    return KeyEventResult.handled;
                  } else if (event.logicalKey == LogicalKeyboardKey.pageDown) {
                    final newOffset = (controller.offset + 200).clamp(0.0, controller.position.maxScrollExtent);
                    controller.jumpTo(newOffset);
                    return KeyEventResult.handled;
                  }
                }
                return KeyEventResult.ignored;
              },
              child: ScrollbarTheme(
                data: ScrollbarThemeData(
                  thumbColor: WidgetStateProperty.all(const Color(0xFFA8D8B9)),
                  trackColor: WidgetStateProperty.all(const Color(0xFF0A0A0A)),
                  trackBorderColor: WidgetStateProperty.all(const Color(0xFF222222)),
                ),
                child: Scrollbar(
                  controller: widget.scrollController,
                  thumbVisibility: true,
                  trackVisibility: true,
                  thickness: 6,
                  radius: const Radius.circular(3),
                  child: SingleChildScrollView(
                    controller: widget.scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: SelectableText.rich(
                      TextSpan(
                        children: widget.entries.map((entry) {
                          return TextSpan(
                            text: '[${entry.time}] ${entry.message}\n',
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'Courier New',
                              letterSpacing: 0.3,
                              color: _getLevelColor(entry.level),
                              height: 1.35,
                            ),
                          );
                        }).toList(),
                      ),
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'Courier New',
                        letterSpacing: 0.3,
                        color: Color(0xFFA8D8B9),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _getLevelColor(String level) {
    switch (level.toUpperCase()) {
      case 'ERROR':
        return const Color(0xFFF4A0A0); // pastel red
      case 'WARN':
        return const Color(0xFFF5D98E); // pastel yellow
      default:
        return const Color(0xFFA8D8B9); // pastel green
    }
  }
}

class LogEntry {
  final String time;
  final String level;
  final String message;

  LogEntry({required this.time, required this.level, required this.message});
}

/// Scene control header widget
class ScenesControlHeader extends StatefulWidget {
  final int currentScene;
  final int totalScenes;
  final List<String> activeCharacters;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onCopy;
  final Function(int)? onJumpToScene;

  const ScenesControlHeader({
    super.key,
    required this.currentScene,
    required this.totalScenes,
    required this.activeCharacters,
    this.onPrevious,
    this.onNext,
    this.onCopy,
    this.onJumpToScene,
  });

  @override
  State<ScenesControlHeader> createState() => _ScenesControlHeaderState();
}

class _ScenesControlHeaderState extends State<ScenesControlHeader> {
  late TextEditingController _jumpController;

  @override
  void initState() {
    super.initState();
    _jumpController = TextEditingController();
  }

  @override
  void dispose() {
    _jumpController.dispose();
    super.dispose();
  }

  void _handleJump() {
    final val = int.tryParse(_jumpController.text);
    if (val != null && widget.onJumpToScene != null) {
      widget.onJumpToScene!(val);
      _jumpController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tp = ThemeProvider();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: tp.surfaceBg,
        border: Border(bottom: BorderSide(color: tp.borderColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Row 1: Scene control and copy button
          Row(
            children: [
              Text(
                'Scenes',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: tp.textPrimary,
                ),
              ),
              const SizedBox(width: 4),
              // Scene navigator
              Container(
                height: 26,
                decoration: BoxDecoration(
                  color: tp.cardBg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: tp.borderColor),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      onTap: widget.onPrevious,
                      borderRadius: const BorderRadius.horizontal(left: Radius.circular(5)),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(Icons.chevron_left, size: 16, color: Color(0xFF64748B)),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        border: Border.symmetric(
                          vertical: BorderSide(color: tp.borderColor),
                        ),
                      ),
                      child: Text(
                        '${widget.currentScene}/${widget.totalScenes}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'monospace',
                          color: tp.textPrimary,
                        ),
                      ),
                    ),
                    InkWell(
                      onTap: widget.onNext,
                      borderRadius: const BorderRadius.horizontal(right: Radius.circular(5)),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(Icons.chevron_right, size: 16, color: Color(0xFF64748B)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              // Jump to scene
              if (widget.onJumpToScene != null) ...[
                SizedBox(
                  width: 36,
                  height: 26,
                  child: TextField(
                    controller: _jumpController,
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    style: TextStyle(fontSize: 11, color: tp.textPrimary),
                    decoration: InputDecoration(
                      contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 2),
                      hintText: '#',
                      hintStyle: TextStyle(color: tp.textTertiary, fontSize: 11),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(5),
                        borderSide: BorderSide(color: tp.borderColor),
                      ),
                    ),
                    onSubmitted: (_) => _handleJump(),
                  ),
                ),
                const SizedBox(width: 2),
                SizedBox(
                  height: 26,
                  child: ElevatedButton(
                    onPressed: _handleJump,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: StudioColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                      minimumSize: Size.zero,
                    ),
                    child: const Text('Go', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
              const Spacer(),
              InkWell(
                onTap: widget.onCopy,
                borderRadius: BorderRadius.circular(4),
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.content_copy, size: 14, color: Color(0xFF64748B)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Row 2: Active tags (more space)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: tp.isDarkMode ? const Color(0xFF1E40AF).withOpacity(0.1) : const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: tp.isDarkMode ? const Color(0xFF1E40AF).withOpacity(0.3) : const Color(0xFFBFDBFE)),
            ),
            child: Row(
              children: [
                const Icon(Icons.label_outline, size: 12, color: Color(0xFF1E40AF)),
                const SizedBox(width: 6),
                const Text(
                  'Active Tags:',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF1E40AF),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.activeCharacters.isEmpty ? 'None' : widget.activeCharacters.join(', '),
                    style: TextStyle(
                      fontSize: 11,
                      color: const Color(0xFF1E40AF).withOpacity(0.8),
                      fontWeight: FontWeight.w400,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
