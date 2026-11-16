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
    // Check standard Python snake_case role mappings
    if (clean == 'index' || clean == 'book_index') return SectionRole.bookIndex;
    if (clean == 'about_author') return SectionRole.aboutAuthor;
    if (clean == 'title_page') return SectionRole.titlePage;
    if (clean == 'half_title') return SectionRole.halfTitle;
    if (clean == 'list_of_figures') return SectionRole.listOfFigures;

    final words = clean.split(RegExp(r'[^a-z0-9]+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return SectionRole.unknown;

    final first = words.first;

    // Whole token or start-of-title matches
    if (words.any((w) => w.startsWith('acknowledg') || w == 'thanks')) {
      return SectionRole.acknowledgments;
    }
    if (words.any((w) => w == 'introduction' || w == 'intro')) {
      return SectionRole.introduction;
    }
    if (words.any((w) => w == 'preface')) {
      return SectionRole.preface;
    }
    if (words.any((w) => w == 'foreword')) {
      return SectionRole.foreword;
    }
    if (words.any((w) => w == 'prologue')) {
      return SectionRole.prologue;
    }
    if (words.any((w) => w == 'epilogue')) {
      return SectionRole.epilogue;
    }
    if (words.any((w) => w == 'afterword')) {
      return SectionRole.afterword;
    }
    if (words.any((w) => w == 'appendix')) {
      return SectionRole.appendix;
    }
    if (words.any((w) => w == 'copyright')) {
      return SectionRole.copyright;
    }
    if (words.any((w) => w == 'dedication')) {
      return SectionRole.dedication;
    }
    if (words.any((w) => w.startsWith('biblio') || w == 'references')) {
      return SectionRole.bibliography;
    }
    if (words.any((w) => w == 'notes' || w == 'endnotes')) {
      return SectionRole.notes;
    }
    if (words.any((w) => w == 'glossary')) {
      return SectionRole.glossary;
    }
    if (clean.contains('table of contents') || clean == 'contents' || clean == 'toc') {
      return SectionRole.toc;
    }
    if (words.any((w) => w == 'contents' || w == 'toc')) {
      return SectionRole.toc;
    }
    if (words.any((w) => w == 'index' && w != 'index_split')) {
      return SectionRole.bookIndex;
    }
    // Chapter: starts with 'chapter' or 'ch'
    if (first == 'chapter' || first == 'ch') {
      return SectionRole.chapter;
    }
    // Part: first token equals 'part'
    if (first == 'part') {
      return SectionRole.part;
    }

    return SectionRole.unknown;
  }
}

