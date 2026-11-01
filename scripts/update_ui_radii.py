"""
Refine UI radii across Athena to eliminate boxiness and enforce concentric, organic pill ergonomics
per make-interfaces-feel-better and flutter-ui-ux skills.
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def refine_processing_screen():
    path = os.path.join(ROOT, "app", "lib", "features", "processing", "screens", "processing_screen.dart")
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()

    # Warning banner
    text = text.replace(
        "borderRadius: BorderRadius.circular(6),\n                      ),\n                      child: Row(\n                        children: [\n                          const Icon(Icons.cloud_off_rounded,",
        "borderRadius: BorderRadius.circular(16),\n                      ),\n                      child: Row(\n                        children: [\n                          const Icon(Icons.cloud_off_rounded,"
    )

    # Hero Card outer shell
    text = text.replace(
        "decoration: BoxDecoration(\n                      color: isDark\n                          ? const Color(0xFF181818)\n                          : const Color(0xFFF7F6F2),\n                      borderRadius: BorderRadius.circular(6),",
        "decoration: BoxDecoration(\n                      color: isDark\n                          ? const Color(0xFF181818)\n                          : const Color(0xFFF7F6F2),\n                      borderRadius: BorderRadius.circular(24),"
    )

    # Hero Card inner core
    text = text.replace(
        "decoration: BoxDecoration(\n                        color: isDark ? const Color(0xFF202020) : Colors.white,\n                        borderRadius: BorderRadius.circular(6),",
        "decoration: BoxDecoration(\n                        color: isDark ? const Color(0xFF202020) : Colors.white,\n                        borderRadius: BorderRadius.circular(20),"
    )

    # Progress bar
    text = text.replace(
        "ClipRRect(\n                            borderRadius: BorderRadius.circular(4),\n                            child: LinearProgressIndicator(",
        "ClipRRect(\n                            borderRadius: BorderRadius.circular(6),\n                            child: LinearProgressIndicator("
    )

    # Stage item card
    text = text.replace(
        "borderRadius: BorderRadius.circular(6),\n                            border: Border.all(\n                              color: isActive",
        "borderRadius: BorderRadius.circular(16),\n                            border: Border.all(\n                              color: isActive"
    )

    # Status tags
    text = text.replace(
        "borderRadius: BorderRadius.circular(4),\n                                   ),\n                                   child: const Text(\n                                     'Done',",
        "borderRadius: BorderRadius.circular(12),\n                                   ),\n                                   child: const Text(\n                                     'Done',"
    )
    text = text.replace(
        "borderRadius: BorderRadius.circular(4),\n                                   ),\n                                   child: const Text(\n                                     'Working',",
        "borderRadius: BorderRadius.circular(12),\n                                   ),\n                                   child: const Text(\n                                     'Working',"
    )
    text = text.replace(
        "borderRadius: BorderRadius.circular(4),\n                                   ),\n                                   child: const Text(\n                                     'Failed',",
        "borderRadius: BorderRadius.circular(12),\n                                   ),\n                                   child: const Text(\n                                     'Failed',"
    )

    # Open In Reader button
    text = text.replace(
        "borderRadius: BorderRadius.circular(6),\n                      child: Container(\n                        width: double.infinity,\n                        height: 54,\n                        padding: const EdgeInsets.symmetric(horizontal: 20),\n                        decoration: BoxDecoration(\n                          color: const Color(0xFF005E54),\n                          borderRadius: BorderRadius.circular(6),",
        "borderRadius: BorderRadius.circular(24),\n                      child: Container(\n                        width: double.infinity,\n                        height: 54,\n                        padding: const EdgeInsets.symmetric(horizontal: 20),\n                        decoration: BoxDecoration(\n                          color: const Color(0xFF005E54),\n                          borderRadius: BorderRadius.circular(24),"
    )

    # Retry button
    text = text.replace(
        "borderRadius: BorderRadius.circular(6),\n                      child: Container(\n                        width: double.infinity,\n                        height: 54,\n                        padding: const EdgeInsets.symmetric(horizontal: 20),\n                        decoration: BoxDecoration(\n                          color: const Color(0xFF141714),\n                          borderRadius: BorderRadius.circular(6),",
        "borderRadius: BorderRadius.circular(24),\n                      child: Container(\n                        width: double.infinity,\n                        height: 54,\n                        padding: const EdgeInsets.symmetric(horizontal: 20),\n                        decoration: BoxDecoration(\n                          color: const Color(0xFF141714),\n                          borderRadius: BorderRadius.circular(24),"
    )

    # Info box
    text = text.replace(
        "decoration: BoxDecoration(\n                        color: isDark\n                            ? const Color(0xFF181818)\n                            : const Color(0xFFF7F6F2),\n                        borderRadius: BorderRadius.circular(6),",
        "decoration: BoxDecoration(\n                        color: isDark\n                            ? const Color(0xFF181818)\n                            : const Color(0xFFF7F6F2),\n                        borderRadius: BorderRadius.circular(20),"
    )
    text = text.replace(
        "decoration: BoxDecoration(\n                          color:\n                              isDark ? const Color(0xFF202020) : Colors.white,\n                          borderRadius: BorderRadius.circular(6),",
        "decoration: BoxDecoration(\n                          color:\n                              isDark ? const Color(0xFF202020) : Colors.white,\n                          borderRadius: BorderRadius.circular(14),"
    )

    # Rejection card
    text = text.replace(
        "decoration: BoxDecoration(\n            color: isDark ? AppTheme.darkSurface : const Color(0xFFFCFBF7),\n            borderRadius: BorderRadius.circular(6),",
        "decoration: BoxDecoration(\n            color: isDark ? AppTheme.darkSurface : const Color(0xFFFCFBF7),\n            borderRadius: BorderRadius.circular(20),"
    )
    text = text.replace(
        "borderRadius: BorderRadius.circular(4),\n                ),\n                child: Text(\n                  'NOT A LONG-FORM READING DOCUMENT',",
        "borderRadius: BorderRadius.circular(12),\n                ),\n                child: Text(\n                  'NOT A LONG-FORM READING DOCUMENT',"
    )
    text = text.replace(
        "shape: RoundedRectangleBorder(\n                      borderRadius: BorderRadius.circular(6),\n                    ),\n                    elevation: 0,\n                  ),\n                  icon: const Icon(Icons.delete_outline_rounded, size: 18),\n                  label: const Text(\n                    'Remove from Library',",
        "shape: RoundedRectangleBorder(\n                      borderRadius: BorderRadius.circular(24),\n                    ),\n                    elevation: 0,\n                  ),\n                  icon: const Icon(Icons.delete_outline_rounded, size: 18),\n                  label: const Text(\n                    'Remove from Library',"
    )

    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    print("processing_screen.dart updated")

def refine_reader_screen():
    path = os.path.join(ROOT, "app", "lib", "features", "reader", "screens", "reader_screen.dart")
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()

    # Vibe check card
    text = text.replace(
        "color: const Color(0xFF141714),\n          borderRadius: BorderRadius.circular(6),",
        "color: const Color(0xFF141714),\n          borderRadius: BorderRadius.circular(16),"
    )
    text = text.replace(
        "color: AppTheme.lime,\n                    borderRadius: BorderRadius.circular(8),",
        "color: AppTheme.lime,\n                    borderRadius: BorderRadius.circular(12),"
    )

    # Bionic focus button
    text = text.replace(
        "shape: RoundedRectangleBorder(\n              borderRadius: BorderRadius.circular(6),\n            ),",
        "shape: RoundedRectangleBorder(\n              borderRadius: BorderRadius.circular(20),\n            ),"
    )

    # Integrity / About dialogs
    text = text.replace(
        "decoration: BoxDecoration(\n            color: isDark ? const Color(0xFF181818) : const Color(0xFFF7F6F2),\n            borderRadius: BorderRadius.circular(6),\n            border: Border.all(\n              color: isDark ? const Color(0xFF282828) : const Color(0xFFE5E7DC),",
        "decoration: BoxDecoration(\n            color: isDark ? const Color(0xFF181818) : const Color(0xFFF7F6F2),\n            borderRadius: BorderRadius.circular(24),\n            border: Border.all(\n              color: isDark ? const Color(0xFF282828) : const Color(0xFFE5E7DC),"
    )
    text = text.replace(
        "decoration: BoxDecoration(\n              color: isDark ? const Color(0xFF202020) : Colors.white,\n              borderRadius: BorderRadius.circular(6),\n              border: Border.all(\n                color:\n                    isDark ? const Color(0xFF2E2E2E) : const Color(0xFFECEEE4),",
        "decoration: BoxDecoration(\n              color: isDark ? const Color(0xFF202020) : Colors.white,\n              borderRadius: BorderRadius.circular(20),\n              border: Border.all(\n                color:\n                    isDark ? const Color(0xFF2E2E2E) : const Color(0xFFECEEE4),"
    )
    text = text.replace(
        "borderRadius: BorderRadius.circular(6),\n                        border: Border.all(\n                          color: Color(0xFF2D6A4F).withValues(alpha: 0.3),",
        "borderRadius: BorderRadius.circular(12),\n                        border: Border.all(\n                          color: Color(0xFF2D6A4F).withValues(alpha: 0.3),"
    )
    text = text.replace(
        "borderRadius: BorderRadius.circular(6),\n                    border: Border.all(\n                      color: isDark\n                          ? const Color(0xFF282828)\n                          : const Color(0xFFE5E7DC),\n                    ),\n                  ),\n                  child: Column(\n                    crossAxisAlignment: CrossAxisAlignment.start,\n                    children: [\n                      Text(\n                        'SHA-256 INTEGRITY CHECKSUM',",
        "borderRadius: BorderRadius.circular(16),\n                    border: Border.all(\n                      color: isDark\n                          ? const Color(0xFF282828)\n                          : const Color(0xFFE5E7DC),\n                    ),\n                  ),\n                  child: Column(\n                    crossAxisAlignment: CrossAxisAlignment.start,\n                    children: [\n                      Text(\n                        'SHA-256 INTEGRITY CHECKSUM',"
    )
    text = text.replace(
        "shape: RoundedRectangleBorder(\n                        borderRadius: BorderRadius.circular(6),\n                      ),\n                      padding: const EdgeInsets.symmetric(vertical: 13),\n                    ),\n                    child: const Text(\n                      'Close',",
        "shape: RoundedRectangleBorder(\n                        borderRadius: BorderRadius.circular(22),\n                      ),\n                      padding: const EdgeInsets.symmetric(vertical: 13),\n                    ),\n                    child: const Text(\n                      'Close',"
    )
    text = text.replace(
        "shape: RoundedRectangleBorder(\n                        borderRadius: BorderRadius.circular(6),\n                      ),\n                      padding: const EdgeInsets.symmetric(vertical: 13),\n                    ),\n                    child: const Text(\n                      'Dismiss',",
        "shape: RoundedRectangleBorder(\n                        borderRadius: BorderRadius.circular(22),\n                      ),\n                      padding: const EdgeInsets.symmetric(vertical: 13),\n                    ),\n                    child: const Text(\n                      'Dismiss',"
    )

    # Segmented reading mode switch (FEED / FLOW)
    text = text.replace(
        "borderRadius: BorderRadius.circular(6),\n                  border: Border.all(color: theme.borderColor),\n                ),\n                child: Row(\n                  mainAxisSize: MainAxisSize.min,\n                  children: [\n                    InkWell(\n                      onTap: () => _setReadingMode('feed'),\n                      borderRadius: BorderRadius.circular(5),\n                      child: Container(\n                        padding: const EdgeInsets.symmetric(\n                            horizontal: 8, vertical: 4),\n                        decoration: BoxDecoration(\n                          color: _readingMode == 'feed'\n                              ? const Color(0xFF2D6A4F)\n                              : Colors.transparent,\n                          borderRadius: BorderRadius.circular(5),\n                        ),",
        "borderRadius: BorderRadius.circular(20),\n                  border: Border.all(color: theme.borderColor),\n                ),\n                child: Row(\n                  mainAxisSize: MainAxisSize.min,\n                  children: [\n                    InkWell(\n                      onTap: () => _setReadingMode('feed'),\n                      borderRadius: BorderRadius.circular(16),\n                      child: Container(\n                        padding: const EdgeInsets.symmetric(\n                            horizontal: 8, vertical: 4),\n                        decoration: BoxDecoration(\n                          color: _readingMode == 'feed'\n                              ? const Color(0xFF2D6A4F)\n                              : Colors.transparent,\n                          borderRadius: BorderRadius.circular(16),\n                        ),"
    )
    text = text.replace(
        "onTap: () => _setReadingMode('flow'),\n                      borderRadius: BorderRadius.circular(5),\n                      child: Container(\n                        padding: const EdgeInsets.symmetric(\n                            horizontal: 8, vertical: 4),\n                        decoration: BoxDecoration(\n                          color: _readingMode == 'flow'\n                              ? const Color(0xFF2D6A4F)\n                              : Colors.transparent,\n                          borderRadius: BorderRadius.circular(5),\n                        ),",
        "onTap: () => _setReadingMode('flow'),\n                      borderRadius: BorderRadius.circular(16),\n                      child: Container(\n                        padding: const EdgeInsets.symmetric(\n                            horizontal: 8, vertical: 4),\n                        decoration: BoxDecoration(\n                          color: _readingMode == 'flow'\n                              ? const Color(0xFF2D6A4F)\n                              : Colors.transparent,\n                          borderRadius: BorderRadius.circular(16),\n                        ),"
    )

    # Saved notes pill & Aa button
    text = text.replace(
        "borderRadius: BorderRadius.circular(6),\n                child: Container(\n                  margin:\n                      const EdgeInsets.symmetric(vertical: 8, horizontal: 4),\n                  padding:\n                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),\n                  decoration: BoxDecoration(\n                    color: theme.innerCardColor,\n                    borderRadius: BorderRadius.circular(6),",
        "borderRadius: BorderRadius.circular(16),\n                child: Container(\n                  margin:\n                      const EdgeInsets.symmetric(vertical: 8, horizontal: 4),\n                  padding:\n                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),\n                  decoration: BoxDecoration(\n                    color: theme.innerCardColor,\n                    borderRadius: BorderRadius.circular(16),"
    )
    text = text.replace(
        "padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),\n              decoration: BoxDecoration(\n                color: theme.innerCardColor,\n                borderRadius: BorderRadius.circular(6),",
        "padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),\n              decoration: BoxDecoration(\n                color: theme.innerCardColor,\n                borderRadius: BorderRadius.circular(16),"
    )

    # Jump to page dialog
    text = text.replace(
        "border: OutlineInputBorder(\n                    borderRadius: BorderRadius.circular(6),",
        "border: OutlineInputBorder(\n                    borderRadius: BorderRadius.circular(14),"
    )
    text = text.replace(
        "enabledBorder: OutlineInputBorder(\n                    borderRadius: BorderRadius.circular(6),",
        "enabledBorder: OutlineInputBorder(\n                    borderRadius: BorderRadius.circular(14),"
    )
    text = text.replace(
        "focusedBorder: OutlineInputBorder(\n                    borderRadius: BorderRadius.circular(6),",
        "focusedBorder: OutlineInputBorder(\n                    borderRadius: BorderRadius.circular(14),"
    )
    text = text.replace(
        "shape: RoundedRectangleBorder(\n                                  borderRadius: BorderRadius.circular(6),",
        "shape: RoundedRectangleBorder(\n                                  borderRadius: BorderRadius.circular(22),"
    )
    text = text.replace(
        "shape: RoundedRectangleBorder(\n                                      borderRadius: BorderRadius.circular(6),",
        "shape: RoundedRectangleBorder(\n                                      borderRadius: BorderRadius.circular(22),"
    )

    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    print("reader_screen.dart updated")

def main():
    refine_processing_screen()
    refine_reader_screen()

if __name__ == "__main__":
    main()
