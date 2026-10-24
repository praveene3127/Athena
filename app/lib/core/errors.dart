class AppError {
  final String code;
  final String message;

  const AppError({required this.code, required this.message});

  static const Map<String, String> userMessages = {
    'UNSUPPORTED_FILE': 'Please choose a PDF or EPUB book.',
    'PDF_UNREADABLE': 'This book could not be read.',
    'PDF_ENCRYPTED': 'This book is password-protected.',
    'RESOURCE_LIMIT':
        'This book exceeded the storage or memory available on this device. Free up space and try again.',
    'SCANNED_NOT_SUPPORTED':
        'This looks like a scanned PDF. Athena currently supports digital PDFs with selectable text.',
    'NO_TEXT': 'No usable text was found in this PDF.',
    'INTERRUPTED': 'Processing was interrupted. Tap retry.',
    'NOT_FOUND': 'That item no longer exists.',
    'INTERNAL': 'Something went wrong. Please try again.',
  };

  static String getDisplayMessage(String code, [String? fallback]) {
    return userMessages[code] ??
        fallback ??
        'Something went wrong. Please try again.';
  }

  factory AppError.fromJson(Map<String, dynamic> json) {
    final err = json['error'] as Map<String, dynamic>? ?? json;
    final code = err['code'] as String? ?? 'INTERNAL';
    final message = err['message'] as String? ?? getDisplayMessage(code);
    return AppError(code: code, message: message);
  }
}
