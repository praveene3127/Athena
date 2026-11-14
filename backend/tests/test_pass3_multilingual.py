import hashlib
import pytest
from app.services.edge.bouncer import _is_prose_page
from app.services.edge.hygiene import (
    is_front_matter_or_noise_page,
    is_predominantly_latin_ascii,
    split_fused_kerning_words,
)
from app.services.ingestion.canonical import find_safe_sentence_boundaries
from app.services.ingestion.chunker import chunk_document, is_legal_cut, _word_count

ENGLISH_PROSE = (
    "The scientific revolution inaugurated an era of unprecedented empirical discovery. "
    "Natural philosophers recognized that mathematical modeling and controlled experimentation "
    "could unveil universal principles of physical reality. Through careful observation, humanity "
    "began to comprehend the intricate mechanics governing celestial motion and earthly dynamics. "
    "Every newly discovered principle laid the foundation for transformative technological advancements."
)

FRENCH_GERMAN_PROSE = (
    "L'intelligence artificielle et l'apprentissage automatique transforment la société moderne. "
    "Les chercheurs développent des algorithmes capables d'analyser des ensembles de données complexes. "
    "Die präzise mathematische Modellierung vernetzter Systeme erfordert tiefes theoretisches Verständnis. "
    "Überraschende wissenschaftliche Erkenntnisse fördern den nachhaltigen industriellen Fortschritt. "
    "Dieser interdisziplinäre Dialog bereichert die globale Forschungsgemeinschaft ungemein."
)

RUSSIAN_PROSE = (
    "Классическая литература раскрывает глубокие философские вопросы человеческого бытия и сознания. "
    "Исследование культурного наследия обогащает внутренний мир читателя и открывает новые горизонты мысли. "
    "Гармония глубокой мысли и выразительного слова формирует подлинную мудрость поколений и эпох. "
    "Научные труды великих мыслителей продолжают вдохновлять исследователей во всем цивилизованном мире. "
    "Преемственность знаний служит прочным фундаментом духовного и культурного развития общества."
)

HINDI_PROSE = (
    "साहित्य समाज का दर्पण होता है और मानवीय संवेदनाओं को गहराई से उजागर करता है। "
    "ज्ञान और तर्कसंगत विचार का संगम प्रत्येक व्यक्ति को विवेकशील और संवेदनशील बनाता है। "
    "प्राचीन ग्रंथों में निहित दार्शनिक चिंतन आज के युग में भी अत्यंत प्रासंगिक और प्रेरणादायक है। "
    "शिक्षा और संस्कृति का समन्वय समाज को प्रगति और सौहार्द के मार्ग पर निरंतर अग्रसर करता है। "
    "सत्य और अहिंसा के शाश्वत मूल्य मानवता के कल्याण और विश्व शांति का मार्ग प्रशस्त करते हैं।"
)

ARABIC_PROSE = (
    "إن القراءة غذاء العقل ونافذة يطل منها الإنسان على عوالم جديدة وتجارب ملهمة ومفيدة في الحياة. "
    "المعرفة تبني الحضارات وترتقي بالأمم نحو مستقبل أكثر إشراقاً وتطوراً وازدهاراً دائماً ومستمراً. "
    "التفكر والتدبر في العلوم والآداب يمنح الروح عمقاً وبصيرة نافذة لفهم الكون والمجتمع البشري. "
    "العلم والبحث المستمر هما الأساس المتين لكل نهضة إنسانية مستدامة عبر التاريخ الطويل. "
    "الحوار البناء بين الثقافات يثري الفكر الإنساني ويعزز قيم التسامح والتعايش السلمي الخلاق."
)

CHINESE_PROSE = (
    "读书是一场穿越时空的心灵对话。在静谧的书页之间，历史的智慧与当下的思考悄然交汇。"
    "探索未知的旅程不仅拓宽了视野，更赋予生命以深刻的意义与宁静的力量。"
    "科学与人文的融合推动着人类社会的持续进步与繁荣。每一项重大发现都凝聚着前人无数的心血。"
    "面对广袤的宇宙与复杂的世界，保持谦逊与好奇心是求知探索最重要的优秀品质。"
    "文化的传承连接着过去与未来，照亮了文明前行的壮丽航程与无限可能。"
)


def test_is_predominantly_latin_ascii():
    assert is_predominantly_latin_ascii(ENGLISH_PROSE) is True
    assert is_predominantly_latin_ascii(FRENCH_GERMAN_PROSE) is True
    assert is_predominantly_latin_ascii(RUSSIAN_PROSE) is False
    assert is_predominantly_latin_ascii(HINDI_PROSE) is False
    assert is_predominantly_latin_ascii(ARABIC_PROSE) is False
    assert is_predominantly_latin_ascii(CHINESE_PROSE) is False


def test_non_latin_books_not_rejected_as_front_matter():
    for name, sample in [
        ("Russian", RUSSIAN_PROSE),
        ("Hindi", HINDI_PROSE),
        ("Arabic", ARABIC_PROSE),
        ("Chinese", CHINESE_PROSE),
    ]:
        is_front = is_front_matter_or_noise_page(1, 100, sample)
        assert is_front is False, f"{name} prose should not be rejected as front matter"


def test_split_fused_kerning_skips_non_latin():
    # Russian or Arabic text must not be butchered by English wordninja
    healed = split_fused_kerning_words(RUSSIAN_PROSE)
    assert healed == RUSSIAN_PROSE


def test_is_prose_page_multilingual():
    # Real prose in global languages (with standard page length >= 90 words) must be admitted as valid prose pages
    english_full_page = (
        ENGLISH_PROSE + " " +
        "Furthermore, empirical methodologies established standard criteria for peer review and reproducibility. "
        "Philosophical debates concerning induction and deduction stimulated creative approaches to understanding natural laws. "
        "Over centuries, systematic investigation revealed the underlying unity connecting disparate natural phenomena across the cosmos. "
        "Modern scientific exploration continues to expand the frontiers of human knowledge and technological capabilities."
    )
    french_german_full = (
        FRENCH_GERMAN_PROSE + " " +
        "De plus, les méthodes scientifiques contemporaines intègrent des simulations numériques avancées. "
        "Wissenschaftliche Erkenntnisse bilden das Fundament für gesellschaftlichen Wohlstand und technologische Innovation. "
        "Gemeinsame europäische Forschungsinitiativen stärken die internationale wissenschaftliche Zusammenarbeit nachhaltig und wirksam. "
        "Das Streben nach Erkenntnis verbindet Generationen von Forschern über alle Grenzen hinweg."
    )
    russian_full = (
        RUSSIAN_PROSE + " " +
        "Более того, глубокий критический анализ литературных произведений помогает осмыслить исторический путь человечества. "
        "Творчество великих писателей объединяет разные поколения вокруг непреходящих гуманистических ценностей и идеалов добра. "
        "Стремление к истине и прекрасному остается главным ориентиром для гармоничного развития человеческой личности. "
        "Культурное наследие открывает неиссякаемый источник вдохновения и созидательной энергии."
    )
    hindi_full = (
        HINDI_PROSE + " " +
        "इसके अतिरिक्त, भारतीय दर्शन में वसुधैव कुटुम्बकम् की भावना समस्त विश्व को एक परिवार मानती है। "
        "सदाचार और सद्विचार का प्रसार समाज को नैतिक शक्ति प्रदान करता है और शांति का संचार करता है। "
        "सद्भावना और करुणा के संदेश से ही मानवता का वास्तविक विकास और उत्थान संभव होता है। "
        "ज्ञान की यह अविरल धारा युगों-युगों से मानव समाज का मार्गदर्शन करती आ रही है।"
    )
    arabic_full = (
        ARABIC_PROSE + " " +
        "علاوة على ذلك، فإن المكتبات ودور العلم كانت ولا تزال منارات تشع بالنور والمعرفة للأجيال المتعاقبة عبر العصور. "
        "إن الاستثمار في العقول والتعليم هو الاستثمار الحقيقي والأكثر جدوى لبناء مستقبل واعد للأوطان والشعوب كافة. "
        "تسهم حركة الترجمة النشطة في مد جسور التفاهم والتعاون الإيجابي بين الحضارات الإنسانية المتنوعة والثرية. "
        "القراءة الواعية تصنع وعياً مجتمعياً راقياً يسهم في النهضة الشاملة."
    )
    chinese_full = (
        CHINESE_PROSE + " " +
        "此外，博大精深的思想体系为现代文明的发展提供了源源不断的精神滋养与思想指引。"
        "立足当下而回望历史，我们更加深刻地认识到人文精神在推动社会进步中所扮演的核心角色。"
        "求索真理的脚步永不停歇，在探索未知的广阔征程中不断开创更加美好的辉煌明天与灿烂画卷。"
        "读书不仅能够启迪智慧，更能塑造坚韧不拔的崇高品格与远大志向。"
    )

    assert _is_prose_page(english_full_page) is True
    assert _is_prose_page(french_german_full) is True
    assert _is_prose_page(russian_full) is True
    assert _is_prose_page(hindi_full) is True
    assert _is_prose_page(arabic_full) is True
    assert _is_prose_page(chinese_full) is True


def test_multilingual_sentence_boundaries():
    cjk_text = "第一句话是关于科学的。第二句话是关于文学的。第三句话是关于哲学的。"
    b_cjk = find_safe_sentence_boundaries(cjk_text)
    assert len(b_cjk) >= 2

    hindi_text = "साहित्य समाज का दर्पण होता है। ज्ञान और विचार का संगम व्यक्ति को विवेकशील बनाता है।"
    b_hi = find_safe_sentence_boundaries(hindi_text)
    assert len(b_hi) >= 1

    arabic_text = "هل القراءة غذاء العقل؟ المعرفة تبني الحضارات وترتقي بالأمم."
    b_ar = find_safe_sentence_boundaries(arabic_text)
    assert len(b_ar) >= 1


def test_lossless_multilingual_chunking():
    for name, text in [
        ("English", ENGLISH_PROSE),
        ("French/German", FRENCH_GERMAN_PROSE),
        ("Russian", RUSSIAN_PROSE),
        ("Hindi", HINDI_PROSE),
        ("Arabic", ARABIC_PROSE),
        ("Chinese", CHINESE_PROSE),
    ]:
        units = [{"start": 0, "end": len(text), "page_start": 1, "page_end": 1, "role": "chapter", "raw_text": text}]
        chunks = chunk_document(
            doc_id=f"doc_{name.lower().replace('/', '_')}",
            canonical_text=text,
            spans=units,
        )

        assert len(chunks) >= 1, f"Should produce chunks for {name}"
        reconstructed = "".join(c["raw_text"] for c in chunks)
        assert reconstructed == text, f"100% byte-exact reconstruction required for {name}"
        assert hashlib.sha256(reconstructed.encode("utf-8")).hexdigest() == hashlib.sha256(text.encode("utf-8")).hexdigest()


def test_cjk_word_count():
    cjk = "读书是一场穿越时空的心灵对话。在静谧的书页之间，历史的智慧与当下的思考悄然交汇。"
    wc = _word_count(cjk)
    assert 10 <= wc <= 20
