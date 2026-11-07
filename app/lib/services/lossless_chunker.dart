import 'package:crypto/crypto.dart';
import 'dart:convert';

// Pre-compiled top-level RegExps (Zero runtime re-compilation)
final _punctLetterRe = RegExp(r'([.,!?;:])([A-Za-z“"‘\x27])');
final _ellipsisLetterRe = RegExp(r'(\x2e{2,})([A-Za-z“"‘\x27])');
final _letterEllipsisRe = RegExp(r'([A-Za-z])(\x2e{2,})');
final _letterDigitRe = RegExp(r'([A-Za-z])(\d)');
final _digitLetterRe =
    RegExp(r'(\d)(?!(?:st|nd|rd|th)\b)([A-Za-z])', caseSensitive: false);
final _multiSpaceRe = RegExp(r'[ \t]+');
final _spaceNewlineRe = RegExp(r' *\n *');
final _multiNewlineRe = RegExp(r'\n{3,}');
final _isLetterRe = RegExp(r'[A-Za-z]');

/// Normalizes spacing in extracted PDF/EPUB prose.
/// Repairs obvious lost spaces in extracted prose before chunking. It avoids
/// splitting mixed-case words and leaves content inside quotation marks intact.
String sanitizeProseSpacing(String text) {
  if (text.isEmpty) return text;
  var result = text;

  // 1a. Space after punctuation if immediately followed by letter or quote:
  // e.g. "candle.Headmaster" -> "candle. Headmaster", "Nolan,ahusky" -> "Nolan, ahusky"
  result = result.replaceAllMapped(_punctLetterRe, (m) => '${m[1]} ${m[2]}');
  result = result.replaceAllMapped(_ellipsisLetterRe, (m) => '${m[1]} ${m[2]}');
  result = result.replaceAllMapped(_letterEllipsisRe, (m) => '${m[1]} ${m[2]}');
  result = _spaceQuoteBoundaries(result);
  result = result.replaceAllMapped(_letterDigitRe, (m) => '${m[1]} ${m[2]}');
  result = result.replaceAllMapped(_digitLetterRe, (m) => '${m[1]} ${m[2]}');
  result = result.replaceAll(_multiSpaceRe, ' ');
  result = result.replaceAll(_spaceNewlineRe, '\n');
  result = result.replaceAll(_multiNewlineRe, '\n\n');

  // 7. Split fused lowercase tokens caused by PDF kerning / justification space drops
  // e.g. "Thefourboyswhocarriedbannersmarchedsolemnlytothedais" -> "The four boys who carried banners marched solemnly to the dais"
  result = result.split('\n').map((line) {
    return line.split(' ').map(_segmentFusedWord).join(' ');
  }).join('\n');

  return result.trim();
}

String _spaceQuoteBoundaries(String text) {
  final out = StringBuffer();
  var doubleQuoteIsOpening = true;
  bool isWord(String? value) =>
      value != null && RegExp(r'[A-Za-z0-9]').hasMatch(value);
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    final previous = i > 0 ? text[i - 1] : null;
    final next = i + 1 < text.length ? text[i + 1] : null;
    if (char == '"') {
      if (doubleQuoteIsOpening && isWord(previous)) out.write(' ');
      out.write(char);
      if (!doubleQuoteIsOpening && isWord(next)) out.write(' ');
      doubleQuoteIsOpening = !doubleQuoteIsOpening;
    } else if (char == '“' || char == '‘') {
      if (isWord(previous)) out.write(' ');
      out.write(char);
    } else if (char == '”') {
      out.write(char);
      if (isWord(next)) out.write(' ');
    } else if (char == '’') {
      final isContraction = isWord(previous) && isWord(next);
      out.write(char);
      if (!isContraction && isWord(next)) out.write(' ');
    } else {
      out.write(char);
    }
  }
  return out.toString();
}

const Set<String> _scientificCompounds = {
  'neuroplasticity',
  'electromagnetism',
  'thermodynamics',
  'photosynthesis',
  'crystallography',
  'biotechnology',
  'paleontology',
  'socioeconomic',
  'cardiovascular',
  'counterintuitive',
  'understanding',
  'notwithstanding',
  'nevertheless',
  'straightforward',
  'groundbreaking',
  'infrastructure',
  'representative',
  'responsibility',
  'characteristic',
  'simultaneously',
  'telecommunications',
  'interchangeable',
  'congratulations',
  'superintendent',
  'acknowledgment',
  'institutional',
};

const Set<String> _singleDictionaryWords = {
  'mcdonald',
  'headmaster',
  'dramatically',
  'expectantly',
  'procession',
  'concluded',
  'knowledge',
  'gentlemen',
  'applauded',
  'politely',
  'gentleman',
  'banners',
  'solemnly',
  'lighted',
  'sixties',
  'watching',
  'pointing',
  'stepped',
  'carried',
  'followed',
  'elderly',
  'proudly',
  'standing',
  'understanding',
  'conversation',
  'immediately',
  'particular',
  'particularly',
  'circumstance',
  'circumstances',
  'opportunity',
  'opportunities',
  'information',
  'development',
  'experience',
  'experiences',
  'government',
  'difference',
  'differences',
  'important',
  'impossible',
  'everything',
  'everyone',
  'something',
  'someone',
  'anything',
  'anyone',
  'themselves',
  'ourselves',
  'yourself',
  'yourselves',
  'himself',
  'herself',
  'itself',
  'another',
  'together',
  'without',
  'throughout',
  'however',
  'therefore',
  'furthermore',
  'moreover',
  'meanwhile',
  'otherwise',
  'sometimes',
  'somewhere',
  'anywhere',
  'everywhere',
  'nowhere',
  'already',
  'always',
  'almost',
  'around',
  'against',
  'between',
  'behind',
  'beyond',
  'beside',
  'besides',
  'before',
  'beneath',
  'during',
  'across',
  'toward',
  'towards',
  'inside',
  'outside',
  'within',
  'because',
  'although',
  'though',
  'through',
  'enough',
  'several',
  'certain',
  'certainly',
  'perhaps',
  'probably',
  'actually',
  'finally',
  'suddenly',
  'quickly',
  'slowly',
  'quietly',
  'loudly',
  'clearly',
  'really',
  'simply',
  'easily',
  'hardly',
  'nearly',
  'deeply',
  'greatly',
  'highly',
  'widely',
  'surely',
};

final Set<String> _fusedDictWords = <String>{
  ..._scientificCompounds,
  ..._singleDictionaryWords,
  'a',
  'about',
  'above',
  'across',
  'act',
  'acts',
  'action',
  'actions',
  'after',
  'again',
  'against',
  'age',
  'ago',
  'air',
  'all',
  'almost',
  'alone',
  'along',
  'already',
  'also',
  'although',
  'always',
  'am',
  'among',
  'an',
  'and',
  'another',
  'answer',
  'answered',
  'any',
  'anyone',
  'anything',
  'appear',
  'appeared',
  'applaud',
  'applauded',
  'applause',
  'are',
  'area',
  'arm',
  'arms',
  'army',
  'around',
  'art',
  'as',
  'ask',
  'asked',
  'asking',
  'at',
  'audience',
  'away',
  'back',
  'bad',
  'banner',
  'banners',
  'be',
  'beat',
  'beautiful',
  'beauty',
  'became',
  'because',
  'become',
  'becomes',
  'becoming',
  'been',
  'before',
  'began',
  'begin',
  'behind',
  'being',
  'believe',
  'believed',
  'best',
  'better',
  'between',
  'beyond',
  'big',
  'bill',
  'bit',
  'black',
  'blood',
  'blue',
  'board',
  'body',
  'book',
  'books',
  'born',
  'both',
  'boy',
  'boys',
  'break',
  'bring',
  'brings',
  'brother',
  'brought',
  'build',
  'built',
  'but',
  'by',
  'call',
  'called',
  'calling',
  'came',
  'can',
  'candle',
  'cannot',
  'car',
  'care',
  'carried',
  'carry',
  'carrying',
  'case',
  'cause',
  'certain',
  'certainly',
  'change',
  'changed',
  'child',
  'children',
  'church',
  'city',
  'clear',
  'clearly',
  'close',
  'closed',
  'cold',
  'come',
  'comes',
  'coming',
  'complete',
  'conclude',
  'concluded',
  'conclusion',
  'consider',
  'control',
  'cost',
  'could',
  'country',
  'course',
  'court',
  'cover',
  'covered',
  'cry',
  'cried',
  'cut',
  'dais',
  'dark',
  'darkness',
  'day',
  'days',
  'dead',
  'deal',
  'death',
  'decide',
  'decided',
  'deep',
  'deeply',
  'did',
  'die',
  'died',
  'difference',
  'different',
  'do',
  'does',
  'doing',
  'done',
  'door',
  'doors',
  'down',
  'dramatic',
  'dramatically',
  'draw',
  'dream',
  'drive',
  'drop',
  'dropped',
  'due',
  'during',
  'each',
  'early',
  'earth',
  'easy',
  'easily',
  'eat',
  'edge',
  'education',
  'effect',
  'effort',
  'eight',
  'either',
  'elderly',
  'else',
  'end',
  'ended',
  'ending',
  'enough',
  'even',
  'evening',
  'ever',
  'every',
  'everyone',
  'everything',
  'evidence',
  'exact',
  'exactly',
  'expect',
  'expected',
  'expectantly',
  'experience',
  'eye',
  'eyes',
  'face',
  'faces',
  'faced',
  'fact',
  'facts',
  'fall',
  'fell',
  'family',
  'far',
  'fast',
  'father',
  'fear',
  'feel',
  'feeling',
  'felt',
  'few',
  'field',
  'fight',
  'figure',
  'find',
  'finds',
  'finding',
  'fine',
  'fire',
  'first',
  'five',
  'floor',
  'focus',
  'follow',
  'followed',
  'following',
  'food',
  'foot',
  'feet',
  'for',
  'force',
  'form',
  'formed',
  'forward',
  'found',
  'four',
  'free',
  'friend',
  'friends',
  'from',
  'front',
  'full',
  'fully',
  'further',
  'future',
  'gale',
  'game',
  'gave',
  'general',
  'gentle',
  'gentleman',
  'gentlemen',
  'get',
  'gets',
  'getting',
  'girl',
  'girls',
  'give',
  'gives',
  'given',
  'giving',
  'go',
  'goes',
  'going',
  'gone',
  'god',
  'good',
  'got',
  'gotten',
  'great',
  'greatly',
  'green',
  'ground',
  'group',
  'grow',
  'grew',
  'grown',
  'had',
  'hair',
  'half',
  'hand',
  'hands',
  'handed',
  'happen',
  'happened',
  'happy',
  'hard',
  'has',
  'have',
  'having',
  'he',
  'head',
  'heads',
  'headmaster',
  'hear',
  'heard',
  'hearing',
  'heart',
  'heat',
  'heavy',
  'heavily',
  'held',
  'help',
  'helped',
  'her',
  'here',
  'herself',
  'high',
  'highly',
  'hill',
  'him',
  'himself',
  'his',
  'history',
  'hit',
  'hold',
  'holding',
  'home',
  'hope',
  'hoped',
  'hot',
  'hour',
  'hours',
  'house',
  'houses',
  'how',
  'however',
  'huge',
  'human',
  'hundred',
  'husky',
  'husband',
  'i',
  'idea',
  'ideas',
  'if',
  'ill',
  'image',
  'imagine',
  'imagined',
  'important',
  'in',
  'inside',
  'instead',
  'interest',
  'into',
  'is',
  'issue',
  'it',
  'its',
  'itself',
  'job',
  'join',
  'joined',
  'just',
  'keep',
  'keeping',
  'kept',
  'key',
  'kid',
  'kids',
  'kill',
  'killed',
  'kind',
  'knew',
  'know',
  'knows',
  'known',
  'knowing',
  'knowledge',
  'ladies',
  'lady',
  'land',
  'language',
  'large',
  'last',
  'lasted',
  'late',
  'later',
  'laugh',
  'laughed',
  'law',
  'lay',
  'lead',
  'leading',
  'led',
  'learn',
  'learned',
  'least',
  'leave',
  'leaving',
  'left',
  'leg',
  'legs',
  'less',
  'let',
  'letter',
  'letters',
  'level',
  'lie',
  'lies',
  'lying',
  'life',
  'lives',
  'light',
  'lights',
  'lighted',
  'lighting',
  'like',
  'liked',
  'likely',
  'line',
  'lines',
  'list',
  'listen',
  'listened',
  'little',
  'live',
  'lived',
  'living',
  'local',
  'long',
  'longer',
  'look',
  'looks',
  'looked',
  'looking',
  'lose',
  'lost',
  'lot',
  'lots',
  'loud',
  'loudly',
  'love',
  'loved',
  'low',
  'lower',
  'made',
  'main',
  'mainly',
  'major',
  'make',
  'makes',
  'making',
  'man',
  'men',
  'many',
  'march',
  'marched',
  'marching',
  'mark',
  'marked',
  'matter',
  'matters',
  'may',
  'maybe',
  'me',
  'mean',
  'means',
  'meant',
  'meet',
  'meets',
  'meeting',
  'met',
  'member',
  'members',
  'might',
  'mind',
  'minds',
  'minute',
  'minutes',
  'miss',
  'missed',
  'moment',
  'moments',
  'money',
  'month',
  'months',
  'more',
  'morning',
  'most',
  'mostly',
  'mother',
  'move',
  'moves',
  'moved',
  'moving',
  'much',
  'music',
  'must',
  'my',
  'myself',
  'name',
  'names',
  'named',
  'near',
  'nearly',
  'need',
  'needs',
  'needed',
  'never',
  'new',
  'next',
  'night',
  'nights',
  'nine',
  'no',
  'nolan',
  'none',
  'nor',
  'not',
  'note',
  'notes',
  'noted',
  'nothing',
  'notice',
  'noticed',
  'now',
  'number',
  'numbers',
  'of',
  'off',
  'often',
  'oh',
  'old',
  'older',
  'oldest',
  'on',
  'once',
  'one',
  'ones',
  'only',
  'open',
  'opened',
  'opening',
  'or',
  'order',
  'ordered',
  'other',
  'others',
  'our',
  'ours',
  'ourselves',
  'out',
  'outside',
  'over',
  'own',
  'owned',
  'owner',
  'page',
  'pages',
  'paper',
  'part',
  'parts',
  'pass',
  'passes',
  'passed',
  'passing',
  'past',
  'pay',
  'paid',
  'paying',
  'people',
  'person',
  'place',
  'places',
  'placed',
  'plan',
  'plans',
  'planned',
  'play',
  'played',
  'playing',
  'podium',
  'point',
  'points',
  'pointed',
  'pointing',
  'polite',
  'politely',
  'poor',
  'power',
  'present',
  'process',
  'procession',
  'proud',
  'proudly',
  'problem',
  'problems',
  'put',
  'puts',
  'putting',
  'question',
  'questions',
  'quick',
  'quickly',
  'quiet',
  'quietly',
  'quite',
  'rather',
  'read',
  'reading',
  'real',
  'really',
  'reason',
  'reasons',
  'receive',
  'received',
  'red',
  'remain',
  'remained',
  'remember',
  'remembered',
  'report',
  'reported',
  'rest',
  'return',
  'returned',
  'right',
  'rights',
  'room',
  'rooms',
  'round',
  'run',
  'running',
  'ran',
  'said',
  'same',
  'saw',
  'say',
  'says',
  'saying',
  'school',
  'schools',
  'see',
  'sees',
  'seeing',
  'seen',
  'seem',
  'seems',
  'seemed',
  'seeming',
  'self',
  'send',
  'sends',
  'sending',
  'sent',
  'set',
  'sets',
  'setting',
  'several',
  'shall',
  'she',
  'short',
  'should',
  'show',
  'shows',
  'showed',
  'shown',
  'showing',
  'side',
  'sides',
  'sight',
  'simple',
  'simply',
  'since',
  'sit',
  'sits',
  'sitting',
  'sat',
  'six',
  'sixty',
  'sixties',
  'small',
  'smaller',
  'so',
  'solemn',
  'solemnly',
  'some',
  'someone',
  'something',
  'sometimes',
  'son',
  'sons',
  'soon',
  'sound',
  'sounds',
  'sounded',
  'speak',
  'speaks',
  'speaking',
  'spoke',
  'spoken',
  'special',
  'stand',
  'stands',
  'standing',
  'stood',
  'start',
  'starts',
  'started',
  'starting',
  'state',
  'states',
  'stated',
  'stay',
  'stays',
  'stayed',
  'staying',
  'step',
  'steps',
  'stepped',
  'stepping',
  'still',
  'stop',
  'stops',
  'stopped',
  'stopping',
  'story',
  'stories',
  'strong',
  'strongly',
  'student',
  'students',
  'study',
  'studies',
  'studied',
  'studying',
  'such',
  'sudden',
  'suddenly',
  'sure',
  'surely',
  'table',
  'tables',
  'take',
  'takes',
  'taking',
  'took',
  'taken',
  'talk',
  'talks',
  'talked',
  'talking',
  'tall',
  'teach',
  'teaches',
  'teaching',
  'taught',
  'teacher',
  'teachers',
  'tell',
  'tells',
  'telling',
  'told',
  'ten',
  'than',
  'thank',
  'thanked',
  'thanks',
  'that',
  'the',
  'their',
  'theirs',
  'them',
  'themselves',
  'then',
  'there',
  'therefore',
  'these',
  'they',
  'thing',
  'things',
  'think',
  'thinks',
  'thinking',
  'thought',
  'thoughts',
  'this',
  'those',
  'though',
  'three',
  'through',
  'throughout',
  'thus',
  'time',
  'times',
  'to',
  'today',
  'together',
  'too',
  'top',
  'toward',
  'towards',
  'town',
  'towns',
  'true',
  'truly',
  'truth',
  'try',
  'tries',
  'tried',
  'trying',
  'turn',
  'turns',
  'turned',
  'turning',
  'two',
  'twelve',
  'twenty',
  'under',
  'understand',
  'understands',
  'understood',
  'understanding',
  'until',
  'up',
  'upon',
  'us',
  'use',
  'uses',
  'used',
  'using',
  'usual',
  'usually',
  'very',
  'view',
  'views',
  'voice',
  'voices',
  'wait',
  'waits',
  'waited',
  'waiting',
  'walk',
  'walks',
  'walked',
  'walking',
  'wall',
  'walls',
  'want',
  'wants',
  'wanted',
  'wanting',
  'war',
  'wars',
  'watch',
  'watches',
  'watched',
  'watching',
  'water',
  'way',
  'ways',
  'we',
  'week',
  'weeks',
  'well',
  'went',
  'were',
  'what',
  'whatever',
  'when',
  'where',
  'whether',
  'which',
  'while',
  'white',
  'who',
  'whom',
  'whose',
  'why',
  'wide',
  'widely',
  'will',
  'willing',
  'would',
  'with',
  'within',
  'without',
  'woman',
  'women',
  'word',
  'words',
  'work',
  'works',
  'worked',
  'working',
  'world',
  'worlds',
  'year',
  'years',
  'yes',
  'yet',
  'you',
  'young',
  'your',
  'yours',
  'yourself',
  'yourselves'
};

const Set<String> _topRankWords = {
  'the',
  'a',
  'to',
  'of',
  'and',
  'in',
  'is',
  'it',
  'he',
  'was',
  'for',
  'on',
  'are',
  'as',
  'with',
  'his',
  'they',
  'at',
  'be',
  'this',
  'have',
  'from',
  'or',
  'one',
  'had',
  'by',
  'word',
  'but',
  'not',
  'what',
  'all',
  'were',
  'we',
  'when',
  'your',
  'can',
  'said',
  'there',
  'who',
  'man',
  'men',
  'boys',
  'boy',
  'into',
  'out',
  'up',
  'so',
  'see',
  'no',
  'way',
  'could',
  'my',
  'than',
  'first',
  'been',
  'its',
  'now',
  'find',
  'day',
  'did',
  'get',
  'come',
  'made',
  'part',
  'an'
};

String _segmentFusedWord(String rawWord) {
  if (rawWord.isEmpty) return rawWord;

  // Separate leading punctuation
  int start = 0;
  while (start < rawWord.length && !_isLetterRe.hasMatch(rawWord[start])) {
    start++;
  }
  // Separate trailing punctuation
  int end = rawWord.length;
  while (end > start && !_isLetterRe.hasMatch(rawWord[end - 1])) {
    end--;
  }

  final prefixPunct = rawWord.substring(0, start);
  final core = rawWord.substring(start, end);
  final suffixPunct = rawWord.substring(end);

  final lower = core.toLowerCase();
  if (_scientificCompounds.contains(lower) ||
      _singleDictionaryWords.contains(lower)) {
    return rawWord;
  }

  // Explicit capitalization boundaries are reliable word boundaries in
  // fused PDF text (including acronym-to-title transitions such as
  // "CONTENTSCover"). Keep lowercase-leading forms such as "iPhone" intact.
  final camelParts = core.split(
    RegExp(r'(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])'),
  );
  if (camelParts.length > 1 && camelParts.every((part) => part.length > 1)) {
    return '$prefixPunct${camelParts.join(' ')}$suffixPunct';
  }

  if (end - start < 12) return rawWord;

  // If word has internal hyphens or slashes, keep intact
  if (core.contains('-') || core.contains('/')) return rawWord;

  final segments = _wordBreakDP(lower);
  if (segments == null || segments.length <= 1) {
    return rawWord;
  }

  // Preserve capitalization if first character was capitalized
  final isFirstUpper =
      core[0] == core[0].toUpperCase() && core[0] != core[0].toLowerCase();
  final resultWords = <String>[];
  var sourceOffset = 0;
  for (int i = 0; i < segments.length; i++) {
    var seg = segments[i];
    final sourceStartsUpper = sourceOffset < core.length &&
        core[sourceOffset] == core[sourceOffset].toUpperCase() &&
        core[sourceOffset] != core[sourceOffset].toLowerCase();
    final sourceSegment = core.substring(
      sourceOffset,
      (sourceOffset + segments[i].length).clamp(0, core.length),
    );
    final sourceIsAllCaps = sourceSegment.isNotEmpty &&
        sourceSegment == sourceSegment.toUpperCase() &&
        sourceSegment != sourceSegment.toLowerCase();
    if (sourceIsAllCaps) {
      seg = seg.toUpperCase();
    } else if ((i == 0 && isFirstUpper || sourceStartsUpper) && seg.isNotEmpty) {
      seg = seg[0].toUpperCase() + seg.substring(1);
    }
    resultWords.add(seg);
    sourceOffset += segments[i].length;
  }

  return '$prefixPunct${resultWords.join(' ')}$suffixPunct';
}

List<String>? _wordBreakDP(String s) {
  final n = s.length;
  final dp = List<List<String>?>.filled(n + 1, null);
  final costs = List<int>.filled(n + 1, 999999);
  dp[0] = [];
  costs[0] = 0;

  for (int i = 1; i <= n; i++) {
    final minJ = (i - 22) < 0 ? 0 : i - 22;
    for (int j = i - 1; j >= minJ; j--) {
      if (dp[j] != null) {
        final sub = s.substring(j, i);
        if (_fusedDictWords.contains(sub)) {
          int wordWeight = _topRankWords.contains(sub) ? 1 : 3;
          if (sub.length == 1 && sub != 'a' && sub != 'i') {
            wordWeight = 50;
          }
          final newCost = costs[j] + wordWeight;
          if (newCost < costs[i]) {
            costs[i] = newCost;
            dp[i] = [...dp[j]!, sub];
          }
        }
      }
    }
  }

  return dp[n];
}

/// Reproduces Athena's adaptive feed chunking rules on the device. Every
/// returned range is a direct slice of canonicalText; no text is regenerated.
class LosslessChunker {
  static const int _minWords = 25;
  static const int _maxWords = 65;
  static const int _maxChars = 380;

  static final RegExp _continuationStart = RegExp(
    r'^(however|therefore|thus|moreover|furthermore|for example|for instance|as a result|in contrast|because|but|and|so|this|these|they|it)\b',
    caseSensitive: false,
  );
  static final RegExp _token = RegExp(r'[A-Za-z]{4,}');
  static final Set<String> _stopwords = {
    'about',
    'after',
    'also',
    'among',
    'because',
    'been',
    'before',
    'being',
    'between',
    'could',
    'does',
    'each',
    'from',
    'have',
    'into',
    'just',
    'more',
    'most',
    'over',
    'same',
    'some',
    'such',
    'than',
    'that',
    'their',
    'them',
    'then',
    'there',
    'these',
    'they',
    'this',
    'those',
    'through',
    'under',
    'very',
    'were',
    'what',
    'when',
    'where',
    'which',
    'while',
    'with',
    'would',
  };
  static const Set<String> _abbreviations = {
    'et al.',
    'fig.',
    'figs.',
    'e.g.',
    'i.e.',
    'dr.',
    'mr.',
    'mrs.',
    'ms.',
    'prof.',
    'vol.',
    'no.',
    'pp.',
    'vs.',
    'ca.',
    'cf.',
    'al.',
    'inc.',
    'ltd.',
    'jr.',
    'sr.',
    'approx.',
    'dept.',
    'est.',
    'min.',
    'sec.',
    'univ.',
    'ed.',
    'eds.',
    'ref.',
    'refs.',
    'eq.',
    'eqs.',
    'p.',
    'ch.',
  };
  static final RegExp _sentenceCandidate = RegExp(
    r'([.!?])(\s+)(?=[A-Z0-9"(])',
  );
  static final RegExp _word = RegExp(r'\S+');

  List<Map<String, Object?>> build({
    required String documentId,
    required String canonicalText,
    required List<Map<String, dynamic>> spans,
    int initialSequence = 1,
    int offsetDelta = 0,
  }) {
    if (canonicalText.isEmpty) return const [];
    final units = _paragraphUnits(canonicalText, spans);
    final targetWords = _targetWords(units);
    final atoms = _makeAtoms(canonicalText, units);
    final ranges = _plan(canonicalText, atoms, targetWords);

    var expectedStart = 0;
    for (final range in ranges) {
      final first = atoms[range.$1];
      final last = atoms[range.$2 - 1];
      if (first.start != expectedStart || last.end <= first.start) {
        throw StateError('Adaptive chunking produced a gap or overlap.');
      }
      expectedStart = last.end;
    }
    if (expectedStart != canonicalText.length) {
      throw StateError('Adaptive chunking did not cover the full source.');
    }

    final canonicalHash = _sha256(canonicalText);
    var previousEnd = 0;
    final result = <Map<String, Object?>>[];
    for (var i = 0; i < ranges.length; i++) {
      final (atomStart, atomEnd) = ranges[i];
      final first = atoms[atomStart];
      final last = atoms[atomEnd - 1];
      final start = first.start;
      final end = last.end;
      if (start != previousEnd) {
        throw StateError('Adaptive chunking produced non-contiguous offsets.');
      }
      final rawText = canonicalText.substring(start, end);
      final seq = initialSequence + i;
      result.add({
        'id': '$documentId-c${seq.toString().padLeft(4, '0')}',
        'document_id': documentId,
        'sequence': seq,
        'section_title': atoms
            .skip(atomStart)
            .take(atomEnd - atomStart)
            .map((atom) => atom.sectionTitle)
            .whereType<String>()
            .firstOrNull,
        'raw_text': rawText,
        'source_pages_json': jsonEncode(_pagesForSpan(start, end, spans)),
        'start_offset': start + offsetDelta,
        'end_offset': end + offsetDelta,
        'checksum': _sha256(rawText),
        'boundary_method': last.boundaryAfter,
        'canonical_sha256': canonicalHash,
      });
      previousEnd = end;
    }
    if (previousEnd != canonicalText.length) {
      throw StateError('Chunk output did not reconstruct the source text.');
    }
    return result;
  }

  String _sha256(String text) => sha256.convert(utf8.encode(text)).toString();

  List<int> _pagesForSpan(
    int start,
    int end,
    List<Map<String, dynamic>> spans,
  ) {
    final pages = <int>{};
    for (final span in spans) {
      final spanStart = _asInt(span['start']);
      final spanEnd = _asInt(span['end']);
      if (spanEnd <= start || spanStart >= end) continue;
      final pageStart = _asInt(span['page_start'], fallback: 1);
      final pageEnd = _asInt(span['page_end'], fallback: pageStart);
      for (var page = pageStart; page <= pageEnd; page++) {
        pages.add(page);
      }
    }
    return pages.isEmpty ? [1] : (pages.toList()..sort());
  }

  int _asInt(Object? value, {int fallback = 0}) =>
      value is int ? value : int.tryParse('$value') ?? fallback;

  List<_Unit> _paragraphUnits(
    String text,
    List<Map<String, dynamic>> spans,
  ) {
    final ordered = [...spans]
      ..sort((a, b) => _asInt(a['start']).compareTo(_asInt(b['start'])));
    final units = <_Unit>[];
    var spanIndex = 0;
    var start = 0;
    while (start < text.length) {
      final delimiter = text.indexOf('\n\n', start);
      final contentEnd = delimiter < 0 ? text.length : delimiter;
      final end = delimiter < 0 ? text.length : delimiter + 2;
      final content = text.substring(start, contentEnd);
      while (spanIndex < ordered.length &&
          _asInt(ordered[spanIndex]['end']) <= start) {
        spanIndex++;
      }
      final span = spanIndex < ordered.length &&
              _asInt(ordered[spanIndex]['start']) < contentEnd
          ? ordered[spanIndex]
          : null;
      final type = (span?['type'] as String?) ?? _classify(content);
      units.add(_Unit(
        start: start,
        contentEnd: contentEnd,
        end: end,
        text: content,
        type: type,
        pageStart: _asInt(span?['page_start'], fallback: 1),
        pageEnd: _asInt(span?['page_end'], fallback: 1),
      ));
      start = end;
    }
    return units;
  }

  String _classify(String text) {
    final value = text.trim();
    if (value.isEmpty) return 'paragraph';
    final words = value.split(RegExp(r'\s+'));
    if (RegExp(r'^(figure|fig\.|table|chart|diagram|photo|plate)\s+\d+[:.]?',
            caseSensitive: false)
        .hasMatch(value)) {
      return 'caption';
    }
    if (RegExp(r'[=≠≈≤≥∑∫√α-ωΑ-Ω]{2,}').hasMatch(value) && words.length < 25) {
      return 'formula';
    }
    if (words.length <= 12 &&
        !value.endsWith('.') &&
        !value.endsWith(',') &&
        !value.endsWith(';') &&
        value[0].toUpperCase() == value[0]) {
      return 'heading';
    }
    if (RegExp(r'^(?:[•*\-–—▪▫◦]|\d+[.)]|\([a-zA-Z0-9]+\))\s+')
        .hasMatch(value)) {
      return 'list';
    }
    if (RegExp(r'^["“「『]').hasMatch(value)) return 'quote';
    return 'paragraph';
  }

  int _wordCount(String text) => _word.allMatches(text).length;

  int _targetWords(List<_Unit> units) {
    final lengths = units
        .where((unit) => unit.type != 'heading' && _wordCount(unit.text) > 0)
        .map((unit) => _wordCount(unit.text))
        .toList()
      ..sort();
    if (lengths.isEmpty) return 56;
    final median = lengths[lengths.length ~/ 2];
    final shortRatio =
        lengths.where((length) => length <= 30).length / lengths.length;
    final longRatio =
        lengths.where((length) => length >= 90).length / lengths.length;
    if (median <= 30 && shortRatio >= 0.55) return 48;
    if (median >= 70 || longRatio >= 0.35) return 64;
    return 56;
  }

  List<_Atom> _makeAtoms(String canonicalText, List<_Unit> units) {
    final atoms = <_Atom>[];
    var index = 0;
    while (index < units.length) {
      final unit = units[index];
      if (unit.type == 'heading') {
        final headingStart = unit.start;
        var headingEnd = unit.end;
        var sectionTitle = unit.text.trim();
        index++;
        while (index < units.length && units[index].type == 'heading') {
          headingEnd = units[index].end;
          sectionTitle = '$sectionTitle: ${units[index].text.trim()}';
          index++;
        }
        if (index < units.length) {
          final body = units[index];
          if (body.type == 'contents_entry') {
            atoms.add(_Atom(
              start: headingStart,
              end: body.end,
              wordCount:
                  _wordCount(canonicalText.substring(headingStart, body.end)),
              paragraphId: index,
              boundaryAfter: 'paragraph',
              startsSection: true,
              sectionTitle: sectionTitle,
            ));
            index++;
            continue;
          }
          final isOversized =
              body.text.length > _maxChars || _wordCount(body.text) > _maxWords;
          final slices = isOversized
              ? _splitOversized(body.text)
              : [(0, body.text.length)];
          for (var part = 0; part < slices.length; part++) {
            final slice = slices[part];
            final partStart = part == 0 ? headingStart : body.start + slice.$1;
            final partEnd =
                part == slices.length - 1 ? body.end : body.start + slice.$2;
            atoms.add(_Atom(
              start: partStart,
              end: partEnd,
              wordCount:
                  _wordCount(canonicalText.substring(partStart, partEnd)),
              paragraphId: index,
              boundaryAfter: slices.length > 1 ? 'sentence' : 'paragraph',
              startsSection: part == 0,
              sectionTitle: part == 0 ? sectionTitle : null,
            ));
          }
          index++;
          continue;
        }
        atoms.add(_Atom(
          start: headingStart,
          end: headingEnd,
          wordCount:
              _wordCount(canonicalText.substring(headingStart, headingEnd)),
          paragraphId: index - 1,
          boundaryAfter: 'paragraph',
          startsSection: true,
          sectionTitle: sectionTitle,
        ));
        continue;
      }

      final isOversized =
          unit.text.length > _maxChars || _wordCount(unit.text) > _maxWords;
      final slices =
          isOversized ? _splitOversized(unit.text) : [(0, unit.text.length)];
      for (final slice in slices.indexed) {
        final partIndex = slice.$1;
        final (relativeStart, relativeEnd) = slice.$2;
        final partStart = unit.start + relativeStart;
        final partEnd = partIndex == slices.length - 1
            ? unit.end
            : unit.start + relativeEnd;
        atoms.add(_Atom(
          start: partStart,
          end: partEnd,
          wordCount: _wordCount(canonicalText.substring(partStart, partEnd)),
          paragraphId: index,
          boundaryAfter: slices.length > 1 ? 'sentence' : 'paragraph',
          startsSection: false,
        ));
      }
      index++;
    }
    return atoms;
  }

  List<(int, int)> _splitOversized(String text) {
    if (text.length <= _maxChars && _wordCount(text) <= _maxWords) {
      return [(0, text.length)];
    }

    final pieces = _breakIntoSmallPieces(text);
    final packed = <(int, int)>[];
    var currentStart = 0;
    var currentEnd = 0;

    for (final piece in pieces) {
      final pStart = piece.$1;
      final pEnd = piece.$2;
      if (currentEnd == currentStart) {
        currentStart = pStart;
        currentEnd = pEnd;
        continue;
      }
      final candidateChars = pEnd - currentStart;
      final candidateWords = _wordCount(text.substring(currentStart, pEnd));
      if (candidateChars <= _maxChars && candidateWords <= _maxWords) {
        currentEnd = pEnd;
      } else {
        packed.add((currentStart, currentEnd));
        currentStart = pStart;
        currentEnd = pEnd;
      }
    }
    if (currentEnd > currentStart) {
      packed.add((currentStart, currentEnd));
    }
    return packed.isEmpty ? [(0, text.length)] : packed;
  }

  List<(int, int)> _breakIntoSmallPieces(String text) {
    final sentBoundaries = _safeBoundaries(text);
    final sentenceSpans = <(int, int)>[];
    var prev = 0;
    for (final b in sentBoundaries) {
      if (b > prev && b <= text.length) {
        sentenceSpans.add((prev, b));
        prev = b;
      }
    }
    if (prev < text.length) {
      sentenceSpans.add((prev, text.length));
    }
    if (sentenceSpans.isEmpty) {
      sentenceSpans.add((0, text.length));
    }

    final clauseSpans = <(int, int)>[];
    for (final span in sentenceSpans) {
      final sStart = span.$1;
      final sEnd = span.$2;
      final sText = text.substring(sStart, sEnd);
      if (sText.length <= _maxChars && _wordCount(sText) <= _maxWords) {
        clauseSpans.add((sStart, sEnd));
      } else {
        final subSpans = _splitByClauses(sText);
        for (final sub in subSpans) {
          clauseSpans.add((sStart + sub.$1, sStart + sub.$2));
        }
      }
    }

    final finalPieces = <(int, int)>[];
    for (final span in clauseSpans) {
      final cStart = span.$1;
      final cEnd = span.$2;
      final cText = text.substring(cStart, cEnd);
      if (cText.length <= _maxChars && _wordCount(cText) <= _maxWords) {
        finalPieces.add((cStart, cEnd));
      } else {
        final subSpans = _splitByWordsOrChars(cText);
        for (final sub in subSpans) {
          finalPieces.add((cStart + sub.$1, cStart + sub.$2));
        }
      }
    }

    return finalPieces;
  }

  List<(int, int)> _splitByClauses(String text) {
    final clausePattern = RegExp(r'([;:—–]|,\s+)');
    final matches = clausePattern.allMatches(text).toList();
    if (matches.isEmpty) return [(0, text.length)];

    final result = <(int, int)>[];
    var start = 0;
    for (final m in matches) {
      final end = m.end;
      if (end > start) {
        result.add((start, end));
        start = end;
      }
    }
    if (start < text.length) {
      result.add((start, text.length));
    }
    return result;
  }

  List<(int, int)> _splitByWordsOrChars(String text) {
    final result = <(int, int)>[];
    var start = 0;
    while (start < text.length) {
      if (text.length - start <= _maxChars &&
          _wordCount(text.substring(start)) <= _maxWords) {
        result.add((start, text.length));
        break;
      }
      var targetEnd = (start + _maxChars).clamp(start + 1, text.length);
      var splitAt = -1;
      for (var i = targetEnd; i > start + 30; i--) {
        if (i < text.length && text[i - 1] == ' ') {
          splitAt = i;
          break;
        }
      }
      if (splitAt == -1) {
        splitAt = targetEnd;
      }
      result.add((start, splitAt));
      start = splitAt;
    }
    return result.isEmpty ? [(0, text.length)] : result;
  }

  List<int> _safeBoundaries(String text) {
    final result = <int>[];
    for (final match in _sentenceCandidate.allMatches(text)) {
      final punctIndex = match.start + 1;
      final whitespaceEnd = match.end;
      if (punctIndex > 0 &&
          punctIndex + 1 < text.length &&
          _isDigit(text.codeUnitAt(punctIndex - 1)) &&
          _isDigit(text.codeUnitAt(punctIndex + 1))) {
        continue;
      }
      var tokenStart = punctIndex - 1;
      while (tokenStart > 0 && text[tokenStart - 1].trim().isNotEmpty) {
        tokenStart--;
      }
      final token = text.substring(tokenStart, punctIndex).toLowerCase();
      if (_abbreviations.contains(token)) {
        continue;
      }
      if (token.length == 2 &&
          _isLetter(token.codeUnitAt(0)) &&
          token.endsWith('.')) {
        continue;
      }
      result.add(whitespaceEnd);
    }
    return result;
  }

  bool _isDigit(int value) => value >= 48 && value <= 57;
  bool _isLetter(int value) =>
      (value >= 65 && value <= 90) || (value >= 97 && value <= 122);

  double _boundaryPenalty(String left, String right, bool sameParagraph) {
    if (right.trim().isEmpty) return 0;
    var penalty = sameParagraph ? 0.12 : 0.0;
    if (_continuationStart.hasMatch(right.trimLeft())) penalty += 0.42;
    final leftTerms = _token
        .allMatches(
            left.length > 600 ? left.substring(left.length - 600) : left)
        .map((match) => match.group(0)!.toLowerCase())
        .where((term) => !_stopwords.contains(term))
        .toSet();
    final rightPrefix = right.length > 600 ? right.substring(0, 600) : right;
    final rightTerms = _token
        .allMatches(rightPrefix)
        .map((match) => match.group(0)!.toLowerCase())
        .where((term) => !_stopwords.contains(term))
        .toSet();
    if (leftTerms.isNotEmpty && rightTerms.isNotEmpty) {
      final overlap = leftTerms.intersection(rightTerms).length /
          (leftTerms.length < rightTerms.length
              ? leftTerms.length
              : rightTerms.length);
      penalty += (overlap * 0.3).clamp(0.0, 0.3);
    }
    return penalty;
  }

  List<(int, int)> _plan(String text, List<_Atom> atoms, int targetWords) {
    if (atoms.isEmpty) return const [];
    final minimumWords = (_minWords > targetWords * 0.55)
        ? _minWords
        : (targetWords * 0.55).floor();
    final costs = List<double>.filled(atoms.length + 1, double.infinity);
    final next = List<int>.filled(atoms.length, atoms.length);
    costs[atoms.length] = 0;

    for (var start = atoms.length - 1; start >= 0; start--) {
      var words = 0;
      for (var end = start; end < atoms.length; end++) {
        if (end > start && atoms[end].startsSection) break;
        final spanChars = atoms[end].end - atoms[start].start;
        if (spanChars > _maxChars && end > start) break;
        words += atoms[end].wordCount;
        if (words > _maxWords && end > start) break;
        final deviation = (words - targetWords) / targetWords;
        var chunkCost = deviation * deviation;
        if (spanChars > _maxChars) {
          final charOverflow = (spanChars - _maxChars) / _maxChars;
          chunkCost += 12 * charOverflow * charOverflow;
        }
        if (words < minimumWords && end + 1 < atoms.length) {
          final shortfall = (minimumWords - words) / minimumWords;
          chunkCost += 2 * shortfall * shortfall;
        }
        if (words > _maxWords) {
          final overflow = (words - _maxWords) / _maxWords;
          chunkCost += 8 * overflow * overflow;
        }
        if (end + 1 < atoms.length) {
          final left = text.substring(atoms[end].start, atoms[end].end);
          final right =
              text.substring(atoms[end + 1].start, atoms[end + 1].end);
          chunkCost += _boundaryPenalty(left, right,
              atoms[end].paragraphId == atoms[end + 1].paragraphId);
          if (atoms[end].boundaryAfter == 'sentence') chunkCost += 0.08;
        }
        final total = chunkCost + costs[end + 1];
        if (total < costs[start]) {
          costs[start] = total;
          next[start] = end + 1;
        }
        if (words > _maxWords) break;
      }
    }

    final ranges = <(int, int)>[];
    var start = 0;
    while (start < atoms.length) {
      final end = next[start];
      if (end <= start) {
        throw StateError('No safe feed boundary after atom $start.');
      }
      ranges.add((start, end));
      start = end;
    }
    return ranges;
  }
}

class _Unit {
  const _Unit({
    required this.start,
    required this.contentEnd,
    required this.end,
    required this.text,
    required this.type,
    required this.pageStart,
    required this.pageEnd,
  });

  final int start;
  final int contentEnd;
  final int end;
  final String text;
  final String type;
  final int pageStart;
  final int pageEnd;
}

class _Atom {
  const _Atom({
    required this.start,
    required this.end,
    required this.wordCount,
    required this.paragraphId,
    required this.boundaryAfter,
    required this.startsSection,
    this.sectionTitle,
  });

  final int start;
  final int end;
  final int wordCount;
  final int paragraphId;
  final String boundaryAfter;
  final bool startsSection;
  final String? sectionTitle;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
