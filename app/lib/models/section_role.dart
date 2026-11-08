/// Semantic document structure roles for book zoning.
///
/// Distinguishes non-reading matter (toc, copyright, titlePage, index, bibliography)
/// from readable front matter (preface, foreword, introduction, prologue, acknowledgments)
/// and body prose (chapter, part).
enum SectionRole {
  cover,
  halfTitle,
  titlePage,
  copyright,
  dedication,
  epigraph,
  toc,
  listOfFigures,
  praise,
  alsoBy,
  foreword,
  preface,
  acknowledgments,
  introduction,
  prologue,
  part,
  chapter,
  epilogue,
  afterword,
  appendix,
  notes,
  glossary,
  bibliography,
  bookIndex,
  aboutAuthor,
  adCard,
  unknown;

  /// Whether this role represents readable prose that should be included in the reading feed.
  bool get isReadable => const {
    SectionRole.foreword,
    SectionRole.preface,
    SectionRole.acknowledgments,
    SectionRole.introduction,
    SectionRole.prologue,
    SectionRole.part,
    SectionRole.chapter,
    SectionRole.epilogue,
    SectionRole.afterword,
    SectionRole.appendix,
    SectionRole.unknown,
  }.contains(this);

  /// Whether this role represents core narrative or exposition body.
  bool get isBody => const {
    SectionRole.prologue,
    SectionRole.part,
    SectionRole.chapter,
    SectionRole.epilogue,
    SectionRole.afterword,
    SectionRole.appendix,
  }.contains(this);

  /// Whether this role is non-reading front-matter or back-matter (excluded from reader feed).
  bool get isMatter => !isReadable;

  /// Human-friendly display label for section headers.
  String get displayLabel {
    switch (this) {
      case SectionRole.foreword:
        return 'Foreword';
      case SectionRole.preface:
        return 'Preface';
      case SectionRole.acknowledgments:
        return 'Acknowledgments';
      case SectionRole.introduction:
        return 'Introduction';
      case SectionRole.prologue:
        return 'Prologue';
      case SectionRole.part:
        return 'Part';
      case SectionRole.chapter:
        return 'Chapter';
      case SectionRole.epilogue:
        return 'Epilogue';
      case SectionRole.afterword:
        return 'Afterword';
      case SectionRole.appendix:
        return 'Appendix';
      case SectionRole.notes:
        return 'Notes';
      case SectionRole.glossary:
        return 'Glossary';
      case SectionRole.bibliography:
        return 'Bibliography';
      case SectionRole.bookIndex:
        return 'Index';
      case SectionRole.aboutAuthor:
        return 'About the Author';
      default:
        return name;
    }
  }

  static SectionRole fromString(String? val) {
    if (val == null || val.trim().isEmpty) return SectionRole.unknown;
    final clean = val.trim().toLowerCase();
    for (final role in SectionRole.values) {
      if (role.name.toLowerCase() == clean) return role;
    }
    // Heuristics for common variations
    if (clean.contains('contents') || clean.contains('toc')) return SectionRole.toc;
    if (clean.contains('preface')) return SectionRole.preface;
    if (clean.contains('foreword')) return SectionRole.foreword;
    if (clean.contains('intro')) return SectionRole.introduction;
    if (clean.contains('prologue')) return SectionRole.prologue;
    if (clean.contains('ack')) return SectionRole.acknowledgments;
    if (clean.contains('chapter')) return SectionRole.chapter;
    if (clean.contains('part')) return SectionRole.part;
    if (clean.contains('epilogue')) return SectionRole.epilogue;
    if (clean.contains('afterword')) return SectionRole.afterword;
    if (clean.contains('appendix')) return SectionRole.appendix;
    if (clean.contains('copyright')) return SectionRole.copyright;
    if (clean.contains('biblio') || clean.contains('references')) return SectionRole.bibliography;
    if (clean.contains('index')) return SectionRole.bookIndex;
    if (clean.contains('notes')) return SectionRole.notes;
    return SectionRole.unknown;
  }
}

