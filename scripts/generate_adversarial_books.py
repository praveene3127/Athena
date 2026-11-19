#!/usr/bin/env python3
"""
Adversarial Book Generator (scripts/generate_adversarial_books.py)

Generates realistic, challenging, multi-page synthetic PDF and EPUB books
across 3 adversarial rounds to stress-test book structure understanding.
"""

import os
import sys
import math
import random
import zipfile
from pathlib import Path

# Use pymupdf
try:
    import fitz
except ImportError:
    import pymupdf as fitz

ROOT_DIR = Path(__file__).resolve().parent.parent
OUTPUT_DIR = ROOT_DIR / "backend" / "data" / "adversarial"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)


def create_blank_pdf(filepath: Path, num_pages: int, width=612, height=792):
    """Creates a basic PyMuPDF document."""
    doc = fitz.open()
    for _ in range(num_pages):
        doc.new_page(width=width, height=height)
    return doc


def generate_book_1a_messy_ocr_seminar():
    """
    Book 1A — Messy OCR Academic Seminar:
    - Half-title, intentionally blank page
    - Imprint with fused ALL-CAPS ('NOTESOFTHESEMINAR')
    - 2-page OCR-corrupted TOC with Roman (IX, XXll) + Arabic (3, 21, ;)8, sG), NO dot leaders
    - 3-page Introduction (Roman pages vii, viii, ix)
    - 4 seminar sessions with margin numbers ('¶ 12') in left gutter
    - Endnotes
    """
    path = OUTPUT_DIR / "book_1a_messy_ocr_seminar.pdf"
    doc = fitz.open()
    width, height = 612, 792

    # Page 1: Half-title
    p1 = doc.new_page(width=width, height=height)
    p1.insert_text((150, 300), "SEMINAR PAPERS IN MODERN PHILOSOPHY", fontsize=16)

    # Page 2: Blank with intentional notice
    p2 = doc.new_page(width=width, height=height)
    p2.insert_text((180, 400), "This p ag e intentionally left blank", fontsize=10)

    # Page 3: Imprint with fused ALL-CAPS
    p3 = doc.new_page(width=width, height=height)
    p3.insert_text((100, 200), "NOTESOFTHESEMINAR ON EPISTEMOLOGY", fontsize=15)
    p3.insert_text((100, 240), "PROCEEDINGS OF THE COLLOQUIUM ON COGNITIVE INQUIRY", fontsize=11)
    p3.insert_text((100, 450), "Copyright 1988 by the Academic Research Council", fontsize=9)
    p3.insert_text((100, 470), "All rights reserved. Printed in the United States.", fontsize=9)
    p3.insert_text((100, 490), "Library of Congress Catalog Card Number: 88-90432", fontsize=9)

    # Page 4: TOC Page 1 (No dot leaders, mixed Roman)
    p4 = doc.new_page(width=width, height=height)
    p4.insert_text((240, 80), "TABLE OF CONTENTS", fontsize=14)
    toc_p4 = [
        ("Preliminary Survey and Epistemological Scope", "IX"),
        ("Methodological Foundations of Empirical Analysis", "XXll"),
        ("Historical Precedents in Rationalist Dialectic", "XXlll"),
        ("Archival Records and Documentary Evidence", "XXI\\'"),
    ]
    y = 130
    for title, pnum in toc_p4:
        p4.insert_text((72, y), title, fontsize=11)
        p4.insert_text((500, y), pnum, fontsize=11)
        y += 40

    # Page 5: TOC Page 2 (OCR-corrupted Arabic numbers)
    p5 = doc.new_page(width=width, height=height)
    p5.insert_text((240, 80), "TABLE OF CONTENTS (Continued)", fontsize=14)
    toc_p5 = [
        ("First Seminar Session: The Problem of Perception", "3"),
        ("Second Seminar Session: Memory and Cognitive Representation", "21"),
        ("Third Seminar Session: Linguistic Relativism and Meaning", ";)8"),
        ("Fourth Seminar Session: Verificationist Epistemology", "sG"),
        ("Concluding Reflections and Editorial Summary", "74"),
    ]
    y = 130
    for title, pnum in toc_p5:
        p5.insert_text((72, y), title, fontsize=11)
        p5.insert_text((500, y), pnum, fontsize=11)
        y += 40

    # Pages 6-8: 3-page Introduction (Roman numerals vii, viii, ix)
    roman_labels = ["vii", "viii", "ix"]
    for i, r_label in enumerate(roman_labels):
        p = doc.new_page(width=width, height=height)
        if i == 0:
            p.insert_text((72, 90), "INTRODUCTION", fontsize=15)
            y = 130
        else:
            y = 80
        intro_text = [
            "The papers assembled in this volume reflect a sustained investigation into the foundations of human knowing.",
            "Our primary objective was to reassess the classical divide between rationalism and empiricism under modern evidentiary standards.",
            "Participants were invited to formulate hypotheses that could withstand both conceptual scrutiny and psychological testing.",
            "In subsequent discussions, several recurring themes emerged regarding the status of perceptual reports and perceptual illusions.",
            "We must acknowledge that sensory information is rarely presented to the conscious mind in an unmediated state.",
            "Instead, cognitive models suggest that perceptual experience is actively constructed through Bayesian inference and prior experience.",
        ]
        for line in intro_text:
            p.insert_text((72, y), line, fontsize=10)
            y += 24
        # Margin Roman page number at bottom
        p.insert_text((290, 740), r_label, fontsize=10)

    # Pages 9-16: 4 Seminar Sessions (Body matter, Arabic 1..8)
    sessions = [
        ("FIRST SEMINAR SESSION: THE PROBLEM OF PERCEPTION", "Perceptual data cannot be severed from intentional orientation."),
        ("SECOND SEMINAR SESSION: MEMORY AND COGNITIVE REPRESENTATION", "Memory structures preserve schematic summaries rather than pixel-perfect veridical records."),
        ("THIRD SEMINAR SESSION: LINGUISTIC RELATIVISM AND MEANING", "Semantic categories shape the efficiency with which concepts are retrieved under temporal pressure."),
        ("FOURTH SEMINAR SESSION: VERIFICATIONIST EPISTEMOLOGY", "Empirical confirmation requires observable divergence between competing theoretical models."),
    ]

    p_arabic = 1
    for s_idx, (s_title, s_thesis) in enumerate(sessions):
        # 2 pages per session
        for page_in_s in range(2):
            p = doc.new_page(width=width, height=height)
            y = 80
            if page_in_s == 0:
                p.insert_text((72, y), s_title, fontsize=12)
                y += 40

            # Left gutter margin paragraph markers (e.g., x=36, while body column is x=72..540)
            para_num = 10 + s_idx * 4 + page_in_s * 2
            p.insert_text((36, y + 2), f"¶ {para_num}", fontsize=8)

            p.insert_text((72, y), f"Paragraph {para_num}. {s_thesis}", fontsize=10)
            y += 26
            body_paras = [
                "The dialectic initiated during our morning proceedings centered upon whether immediate sensory awareness requires conceptual mediation.",
                "Several participants argued that pre-attentive visual features are bound into coherent object representations before explicit lexical concepts intervene.",
                "Experimental observations from tachistoscopic presentations appear to substantiate this view with high statistical significance.",
                "Nevertheless, post-perceptual judgment remains vulnerable to social priming and retrospective verbalization biases.",
                "Consequently, our methodology distinguishes sharply between early sensory signals and higher-order deliberative endorsements.",
            ]
            for bp in body_paras:
                p.insert_text((72, y), bp, fontsize=10)
                y += 24

            # Bottom page number
            p.insert_text((295, 740), str(p_arabic), fontsize=10)
            p_arabic += 1

    # Pages 17-18: Endnotes / Notes (Hanging indent)
    for en_page in range(2):
        p = doc.new_page(width=width, height=height)
        y = 80
        if en_page == 0:
            p.insert_text((72, y), "NOTES AND REFERENCES", fontsize=14)
            y += 40

        notes_data = [
            ("1. Quine, W. V. O. (1951). 'Two Dogmas of Empiricism.' Philosophical Review, 60(1), 20-43.",
             "An influential critique of the analytic-synthetic distinction and verification theory."),
            ("2. Sellars, W. (1956). 'Empiricism and the Philosophy of Mind.' Minnesota Studies, 1, 253-329.",
             "Classic deconstruction of the Myth of the Given in sensory epistemology."),
            ("3. Evans, G. (1982). The Varieties of Reference. Oxford: Clarendon Press.",
             "Rigorous account of non-conceptual content and demonstrative identification."),
            ("4. McDowell, J. (1994). Mind and World. Cambridge: Harvard University Press.",
             "Reconciliation of conceptual capacities with direct perceptual openness to reality."),
        ]
        for note_head, note_body in notes_data:
            # Hanging indent: first line at x=72, continuation at x=90
            p.insert_text((72, y), note_head, fontsize=9)
            y += 18
            p.insert_text((90, y), note_body, fontsize=9)
            y += 28

        p.insert_text((295, 740), str(p_arabic), fontsize=10)
        p_arabic += 1

    doc.save(str(path))
    doc.close()
    print(f"Generated: {path} ({path.stat().st_size:,} bytes)")
    return path


def generate_book_1b_trade_nonfiction():
    """
    Book 1B — Modern Trade Non-Fiction:
    - Praise page, Title page, Copyright, Dedication, Epigraph
    - 2-page Preface
    - 4 Chapters with alternating even book title & odd chapter title running headers
    - Wrapped bottom-of-page footnotes
    - Bibliography with hanging indents
    - 2-column Index
    """
    path = OUTPUT_DIR / "book_1b_trade_nonfiction.pdf"
    doc = fitz.open()
    width, height = 612, 792

    # Page 1: Praise
    p1 = doc.new_page(width=width, height=height)
    p1.insert_text((72, 150), "PRAISE FOR THE ARCHITECTURE OF MIND", fontsize=13)
    p1.insert_text((72, 200), "'A magnificent synthesis of neuroscience and philosophy of mind.' — Science Review", fontsize=10)
    p1.insert_text((72, 240), "'Essential reading for anyone interested in human consciousness.' — Dr. Clara Vance", fontsize=10)

    # Page 2: Title
    p2 = doc.new_page(width=width, height=height)
    p2.insert_text((160, 260), "THE ARCHITECTURE OF MIND", fontsize=18)
    p2.insert_text((190, 300), "Exploring the Structures of Cognition", fontsize=12)
    p2.insert_text((240, 420), "ARTHUR H. PENDRICK", fontsize=11)
    p2.insert_text((250, 600), "Horizon Academic Press", fontsize=10)

    # Page 3: Copyright
    p3 = doc.new_page(width=width, height=height)
    p3.insert_text((72, 500), "Copyright © 2024 by Arthur H. Pendrick", fontsize=9)
    p3.insert_text((72, 520), "All rights reserved. Published by Horizon Academic Press, Boston.", fontsize=9)
    p3.insert_text((72, 540), "ISBN: 978-1-56619-909-4", fontsize=9)

    # Page 4: Dedication
    p4 = doc.new_page(width=width, height=height)
    p4.insert_text((200, 360), "For Eleanor, who taught me to observe.", fontsize=11)

    # Page 5: Epigraph
    p5 = doc.new_page(width=width, height=height)
    p5.insert_text((100, 300), "The mind is not a vessel to be filled, but a fire to be kindled.", fontsize=11)
    p5.insert_text((350, 330), "— Plutarch", fontsize=10)

    # Pages 6-7: 2-page Preface
    for pref_i in range(2):
        p = doc.new_page(width=width, height=height)
        y = 80
        if pref_i == 0:
            p.insert_text((72, y), "PREFACE: THE COGNITIVE REVOLUTION", fontsize=14)
            y += 40
        pref_text = [
            "When cognitive science emerged in the mid-twentieth century, it transformed our perspective on mental life.",
            "No longer viewed as an impenetrable black box, the human brain came to be understood as an information processor.",
            "Our computational metaphors have deepened over decades, evolving from linear algorithms to recurrent networks.",
            "This volume gathers the empirical evidence demonstrating how sensory inputs yield stable conceptual knowledge.",
            "We shall proceed systematically through perception, working memory, semantic networks, and executive reasoning.",
        ]
        for line in pref_text:
            p.insert_text((72, y), line, fontsize=10)
            y += 24
        p.insert_text((295, 740), f"ix" if pref_i == 1 else "viii", fontsize=10)

    # Pages 8-19: 4 Chapters with alternating running headers & bottom footnotes
    chapters = [
        ("CHAPTER 1: PERCEPTION AND ATTENTION", [
            "Perception is our primary conduit to external reality, yet it is profoundly selective.",
            "Every second, our senses receive millions of bits of physical energy from photons and sound waves.",
            "Only a tiny fraction of this stream reaches conscious awareness through attentional filtering.",
            "Inattentional blindness experiments reveal how salient objects can pass entirely unnoticed.",
            "The visual cortex orchestrates edge detection, color constancy, and motion parallax into unified percepts.",
        ]),
        ("CHAPTER 2: WORKING MEMORY DYNAMICS", [
            "Working memory provides the mental workspace upon which ongoing cognition operates.",
            "Baddeley and Hitch replaced the monolithic short-term store with a multicomponent system.",
            "The phonological loop handles verbal rehearsal, while the visuospatial sketchpad manages mental imagery.",
            "The central executive coordinates attention, resolves cognitive conflicts, and suppresses irrelevant stimuli.",
            "Capacity limitations impose strict constraints on human problem-solving and multi-tasking performance.",
        ]),
        ("CHAPTER 3: SEMANTIC REPRESENTATION", [
            "How does the mind store general knowledge about entities, categories, and abstract relationships?",
            "Feature-comparison models assume concepts are decomposing lists of necessary and sufficient properties.",
            "Prototype theory instead proposes that categories possess fuzzy boundaries organized around central exemplars.",
            "Connectionist networks demonstrate how distributed representations support graceful degradation under lesions.",
            "Hierarchical taxonomic structures allow rapid inheritance of biological and functional inferences.",
        ]),
        ("CHAPTER 4: EXECUTIVE REASONING", [
            "Executive function represents the pinnacle of human cognitive architecture and self-directed agency.",
            "Prefrontal cortical regions maintain abstract goals over extended temporal delays despite distractions.",
            "Deductive reasoning evaluates formal validity independent of prior empirical belief congruence.",
            "Heuristics and biases illuminate the adaptive shortcuts that conserve metabolic energy under uncertainty.",
            "The interplay between reflexive intuition and deliberative analysis defines human intellectual life.",
        ]),
    ]

    p_num = 1
    for c_idx, (c_title, c_paras) in enumerate(chapters):
        # 3 pages per chapter
        for p_in_c in range(3):
            p = doc.new_page(width=width, height=height)
            is_even = (p_num % 2 == 0)

            # Running header in top 8% (top <= 45 pt)
            header_text = "THE ARCHITECTURE OF MIND" if is_even else c_title.split(":")[0].strip()
            p.insert_text((72 if is_even else 380, 40), header_text, fontsize=8)

            y = 90
            if p_in_c == 0:
                p.insert_text((72, y), c_title, fontsize=13)
                y += 40

            for para in c_paras:
                p.insert_text((72, y), para, fontsize=10)
                y += 24

            # Bottom footnote on page 2 of each chapter (top >= 600 pt, fontsize=8)
            if p_in_c == 1:
                fn_y = 650
                p.insert_text((72, fn_y), f"1. See Reference note regarding empirical validation of {c_title.split(':')[0]}.", fontsize=8)
                p.insert_text((72, fn_y + 14), "Continuation of footnote examining secondary literature and historical precedents.", fontsize=8)

            # Bottom page number
            p.insert_text((295, 740), str(p_num), fontsize=10)
            p_num += 1

    # Pages 20-21: Bibliography (Hanging indent)
    for b_page in range(2):
        p = doc.new_page(width=width, height=height)
        y = 80
        if b_page == 0:
            p.insert_text((72, y), "BIBLIOGRAPHY AND REFERENCES", fontsize=14)
            y += 40

        bib_entries = [
            ("Baddeley, A. D., & Hitch, G. (1974). 'Working Memory.' Psychology of Learning and Motivation, 8, 47-89.",
             "Seminal introduction of the tripartite working memory framework."),
            ("Chomsky, N. (1959). 'Review of B. F. Skinner's Verbal Behavior.' Language, 35(1), 26-58.",
             "The foundational critique of behaviorism that launched cognitive science."),
            ("Kahneman, D. (2011). Thinking, Fast and Slow. New York: Farrar, Straus and Giroux.",
             "Comprehensive review of dual-process theory and cognitive heuristics."),
            ("Marr, D. (1982). Vision: A Computational Investigation into the Human Representation and Processing of Visual Information.",
             "Formulation of the three levels of computational analysis."),
            ("Tulving, E. (1972). 'Episodic and Semantic Memory.' Organization of Memory, 381-403.",
             "Theoretical distinction between autobiographical recollection and generalized factual knowledge."),
        ]
        for b_head, b_desc in bib_entries:
            p.insert_text((72, y), b_head, fontsize=9)
            y += 16
            p.insert_text((90, y), b_desc, fontsize=9)
            y += 26

        p.insert_text((295, 740), str(p_num), fontsize=10)
        p_num += 1

    # Pages 22-23: 2-column Index
    for idx_page in range(2):
        p = doc.new_page(width=width, height=height)
        y_left = 110
        y_right = 110
        if idx_page == 0:
            p.insert_text((72, 70), "INDEX", fontsize=14)

        col1_items = [
            "Attention, 12, 14, 28, 45",
            "Baddeley, Alan, 15, 17, 30",
            "Behaviorism, 4, 8, 19",
            "Categorization, 22, 25, 33",
            "Chomsky, Noam, 9, 11, 40",
            "Cognitive architecture, 2, 7, 14",
            "Connectionism, 24, 27, 38",
            "Deductive reasoning, 31, 35",
        ]
        col2_items = [
            "Episodic memory, 16, 20, 29",
            "Executive function, 18, 30, 36",
            "Heuristics, 32, 34, 41",
            "Inattentional blindness, 13, 21",
            "Long-term memory, 17, 26, 39",
            "Marr, David, 14, 22, 44",
            "Perception, 11, 13, 27",
            "Working memory, 15, 18, 29",
        ]

        for item in col1_items:
            p.insert_text((72, y_left), item, fontsize=9)
            y_left += 22

        for item in col2_items:
            p.insert_text((320, y_right), item, fontsize=9)
            y_right += 22

        p.insert_text((295, 740), str(p_num), fontsize=10)
        p_num += 1

    doc.save(str(path))
    doc.close()
    print(f"Generated: {path} ({path.stat().st_size:,} bytes)")
    return path


def generate_book_1c_trade_epub():
    """
    Book 1C — EPUB 3 Trade Book:
    - Calibre naming (titlepage.xhtml, text/part0001.html, etc.)
    - Drop caps (<span class="dropcap">T</span>he)
    - Soft hyphens (&shy;)
    - epub:type landmarks (frontmatter, toc, bodymatter, backmatter)
    """
    path = OUTPUT_DIR / "book_1c_trade_epub.epub"

    container_xml = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>"""

    content_opf = """<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="pub-id">urn:uuid:12345678-1234-5678-1234-567812345678</dc:identifier>
    <dc:title>Principles of Natural Systems</dc:title>
    <dc:language>en</dc:language>
    <dc:creator>Dr. Meredith Sterling</dc:creator>
    <meta property="dcterms:modified">2026-03-01T12:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="titlepage" href="titlepage.xhtml" media-type="application/xhtml+xml"/>
    <item id="toc" href="toc.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="part1" href="text/part0001.html" media-type="application/xhtml+xml"/>
    <item id="part2" href="text/part0002.html" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="titlepage"/>
    <itemref idref="toc"/>
    <itemref idref="part1"/>
    <itemref idref="part2"/>
  </spine>
</package>"""

    titlepage_xhtml = """<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Title Page</title></head>
<body epub:type="frontmatter titlepage">
  <div style="text-align: center; margin-top: 20%;">
    <h1>Principles of Natural Systems</h1>
    <h2>Self-Organization in Biological Networks</h2>
    <p>By Dr. Meredith Sterling</p>
    <p>Calibre Edition</p>
  </div>
</body>
</html>"""

    toc_xhtml = """<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Table of Contents</title></head>
<body epub:type="frontmatter toc">
  <nav epub:type="toc" id="toc">
    <h1>Contents</h1>
    <ol>
      <li><a href="text/part0001.html">Chapter 1: Dynamic Equilibrium</a></li>
      <li><a href="text/part0002.html">Chapter 2: Adaptive Feedback Loops</a></li>
    </ol>
  </nav>
</body>
</html>"""

    part1_html = """<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Chapter 1</title>
<style>
.dropcap { font-size: 3em; float: left; margin-right: 0.1em; line-height: 0.8; }
</style>
</head>
<body epub:type="bodymatter chapter">
  <h1>Chapter 1: Dynamic Equilibrium</h1>
  <p><span class="dropcap">T</span>he study of com&shy;plex bio&shy;log&shy;i&shy;cal net&shy;works reveals that sta&shy;bil&shy;i&shy;ty is never sta&shy;tic. In&shy;stead, living sys&shy;tems main&shy;tain home&shy;o&shy;sta&shy;sis through con&shy;tin&shy;u&shy;ous ther&shy;mo&shy;dy&shy;nam&shy;ic ex&shy;change with their am&shy;bi&shy;ent en&shy;vi&shy;ron&shy;ment.</p>
  <p>Enzyme ki&shy;net&shy;ics and al&shy;lo&shy;ster&shy;ic reg&shy;u&shy;la&shy;tion en&shy;sure that cel&shy;lu&shy;lar path&shy;ways re&shy;spond with ex&shy;traor&shy;di&shy;nar&shy;y sen&shy;si&shy;tiv&shy;i&shy;ty to fluc&shy;tu&shy;at&shy;ing sub&shy;strate avail&shy;abil&shy;i&shy;ty.</p>
</body>
</html>"""

    part2_html = """<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Chapter 2</title>
<style>
.dropcap { font-size: 3em; float: left; margin-right: 0.1em; line-height: 0.8; }
</style>
</head>
<body epub:type="bodymatter chapter">
  <h1>Chapter 2: Adaptive Feedback Loops</h1>
  <p><span class="dropcap">N</span>eg&shy;a&shy;tive feed&shy;back serves as the cor&shy;ner&shy;stone of phys&shy;i&shy;o&shy;log&shy;i&shy;cal damp&shy;ing. When per&shy;tur&shy;ba&shy;tions ex&shy;ceed crit&shy;i&shy;cal thresh&shy;olds, par&shy;al&shy;lel sig&shy;nal&shy;ing cas&shy;cades in&shy;sti&shy;tute com&shy;pen&shy;sa&shy;to&shy;ry ad&shy;just&shy;ments.</p>
  <p>In neu&shy;ron&shy;al cir&shy;cuits, syn&shy;ap&shy;tic plas&shy;tic&shy;i&shy;ty re&shy;flects this same ca&shy;pac&shy;i&shy;ty to bal&shy;ance ex&shy;ci&shy;ta&shy;to&shy;ry dri&shy;ve with in&shy;hib&shy;i&shy;to&shy;ry con&shy;trol.</p>
</body>
</html>"""

    with zipfile.ZipFile(path, "w") as zf:
        # mimetype must be first and uncompressed
        zf.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        zf.writestr("META-INF/container.xml", container_xml)
        zf.writestr("OEBPS/content.opf", content_opf)
        zf.writestr("OEBPS/titlepage.xhtml", titlepage_xhtml)
        zf.writestr("OEBPS/toc.xhtml", toc_xhtml)
        zf.writestr("OEBPS/text/part0001.html", part1_html)
        zf.writestr("OEBPS/text/part0002.html", part2_html)

    print(f"Generated: {path} ({path.stat().st_size:,} bytes)")
    return path


def generate_book_2a_skewed_academic():
    """
    Book 2A — Skewed 2-Column Academic Monograph:
    - Spanning chapter headings
    - 1.5° jitter / slight vertical scan wobble (+-2 pt y-wobble per word)
    - Multi-line wrapped TOC without page numbers on line 1
    - Dense bottom-of-page footnotes with superscript markers
    """
    path = OUTPUT_DIR / "book_2a_skewed_academic.pdf"
    doc = fitz.open()
    width, height = 612, 792

    # Page 1: Spanning Title Page
    p1 = doc.new_page(width=width, height=height)
    p1.insert_text((120, 280), "ANALYTICAL FOUNDATIONS OF COMPLEXITY", fontsize=16)
    p1.insert_text((180, 320), "A Mathematical Monograph in Statistical Physics", fontsize=11)
    p1.insert_text((240, 500), "CAMBRIDGE UNIVERSITY PRESS", fontsize=10)

    # Page 2: Multi-line wrapped TOC (Line 1 has no page number, line 2 has page number)
    p2 = doc.new_page(width=width, height=height)
    p2.insert_text((240, 70), "CONTENTS", fontsize=14)
    y = 120
    toc_multiline = [
        ("Chapter 1. Microscopic Interactions and Statistical", "Ensembles in Non-Equilibrium Thermodynamics", "3"),
        ("Chapter 2. Ergodicity Breaking and Phase Transitions", "in Disordered Condensed Matter Systems", "7"),
        ("Chapter 3. Renormalization Group Techniques and", "Scaling Hypotheses in Critical Phenomena", "11"),
    ]
    for line1, line2, pnum in toc_multiline:
        p2.insert_text((72, y), line1, fontsize=10)
        y += 18
        p2.insert_text((90, y), line2, fontsize=10)
        p2.insert_text((500, y), pnum, fontsize=10)
        y += 35

    # Pages 3-12: 2-Column Body with spanning headings and vertical scan wobble (+-2 pt)
    chapters_2a = [
        ("Chapter 1. Microscopic Interactions and Statistical Ensembles", [
            "Statistical mechanics bridges microscopic Hamiltonian dynamics with macroscopic thermodynamics.",
            "Consider a conservative dynamical system endowed with 6N degrees of freedom on phase space.",
            "Liouville's theorem guarantees the conservation of phase space volume along Hamiltonian trajectories.",
            "Consequently, the microcanonical ensemble assumes equal probability for all accessible microstates.",
            "When the system couples to an infinite thermal reservoir, canonical distribution emerges naturally.",
        ]),
        ("Chapter 2. Ergodicity Breaking and Phase Transitions", [
            "Ergodic hypothesis posits that temporal averages along trajectories equal ensemble averages.",
            "In disordered systems such as spin glasses, rugged free-energy landscapes trap dynamics indefinitely.",
            "Spontaneous symmetry breaking signifies the emergence of macroscopic order without symmetric Hamiltonians.",
            "Order parameters quantify the degree of symmetry violation across critical temperature regimes.",
            "Mean field theory provides solvable approximations although neglecting spatial fluctuation correlations.",
        ]),
        ("Chapter 3. Renormalization Group Techniques and Scaling", [
            "At continuous critical points, the correlation length diverges toward infinity.",
            "Diverging correlation lengths render microscopic details irrelevant for macroscopic critical exponents.",
            "Renormalization group transformations integrate out high-momentum degrees of freedom iteratively.",
            "Fixed points of the transformation flow govern universality classes across diverse physical platforms.",
            "Perturbative epsilon expansions yield quantitative predictions in excellent agreement with experiments.",
        ]),
    ]

    page_num = 3
    for ch_title, ch_paras in chapters_2a:
        for p_idx in range(3):
            p = doc.new_page(width=width, height=height)
            y = 70
            if p_idx == 0:
                # Spanning full-width chapter heading
                p.insert_text((72, y), ch_title, fontsize=12)
                y += 35

            # 2 columns: Col 1 x=72..280, Col 2 x=310..520
            # Apply slight vertical jitter (+- 1.5 pt) simulating scan wobble
            jitter = (p_idx % 2 * 2 - 1) * 1.5
            col1_y = y
            for line in ch_paras[:3]:
                p.insert_text((72, col1_y + jitter), line, fontsize=8)
                col1_y += 24

            col2_y = y
            for line in ch_paras[3:]:
                p.insert_text((310, col2_y - jitter), line, fontsize=8)
                col2_y += 24

            # Bottom footnote spanning full width (top >= 620 pt)
            fn_y = 660
            p.insert_text((72, fn_y), f"1. Mathematical proof of Liouville theorem in Chapter {page_num - 2}.", fontsize=7)
            p.insert_text((72, fn_y + 12), "   Derivation assumes non-singular symplectic structure on the manifold.", fontsize=7)

            p.insert_text((295, 740), str(page_num), fontsize=9)
            page_num += 1

    doc.save(str(path))
    doc.close()
    print(f"Generated: {path} ({path.stat().st_size:,} bytes)")
    return path


def generate_book_2b_classic_novel():
    """
    Book 2B — Classic Literary Novel:
    - Roman numeral chapters (I, II, III, IV)
    - Dialogue paragraphs
    - Recurring refrain sentence at chapter bottoms
    - Verse epigraphs
    - Translator note
    """
    path = OUTPUT_DIR / "book_2b_classic_novel.pdf"
    doc = fitz.open()
    width, height = 612, 792

    # Page 1: Title
    p1 = doc.new_page(width=width, height=height)
    p1.insert_text((180, 280), "THE SHADOWED STEPPE", fontsize=18)
    p1.insert_text((230, 320), "A Novel of the Frontier", fontsize=11)
    p1.insert_text((210, 480), "Translated from the Russian", fontsize=10)

    # Page 2: Translator's Note
    p2 = doc.new_page(width=width, height=height)
    p2.insert_text((72, 80), "TRANSLATOR'S PREFACE", fontsize=14)
    trans_text = [
        "In presenting this 19th-century masterpiece to the modern reader, fidelity to tone has been our guiding star.",
        "The prose moves with the deliberate tempo of an overland journey across endless plains.",
        "Certain colloquial idioms have been rendered in their poetic equivalents rather than strict literalisms.",
        "We hope the author's tragic lyricism speaks across the gulf of years with undiminished resonance.",
    ]
    y = 130
    for line in trans_text:
        p2.insert_text((72, y), line, fontsize=10)
        y += 24

    # Page 3: Verse Epigraph
    p3 = doc.new_page(width=width, height=height)
    p3.insert_text((120, 260), "Wind of the eastern steppe,", fontsize=11)
    p3.insert_text((140, 285), "Carry no sorrow home;", fontsize=11)
    p3.insert_text((120, 310), "Dust on the traveler's cloak,", fontsize=11)
    p3.insert_text((140, 335), "Stars on the silent dome.", fontsize=11)
    p3.insert_text((320, 370), "— Folk Song", fontsize=10)

    # Chapters with Roman numeral headings (I, II, III, IV)
    novel_chapters = [
        ("I", [
            "The morning arrived without birdcall or herald, grey as wet slate upon the hills.",
            "'Are you certain of this course?' asked Julian, tightening the leather cinch around his horse.",
            "'I have rarely been certain of anything,' replied Helena with a faint smile, 'yet we must ride.'",
            "They set their faces toward the distant river where the reeds shivered in the damp autumn wind.",
            "Between the low birch ridges, cattle stood motionless, breath rising in pale plumes toward the clouds.",
        ]),
        ("II", [
            "By twilight, the stone marker came into view at the crossroad of the northern salt trail.",
            "'We must shelter here before darkness,' said the old guide, dismounting into the tall grasses.",
            "'Does the watchman still keep the lantern lit?' Julian looked toward the dark turret on the ridge.",
            "'He has not kept it lit these twenty winters,' came the quiet answer, 'yet the stones remember.'",
            "A fire was kindled beneath the overhang, throwing long wavering shadows across their tired faces.",
        ]),
        ("III", [
            "Snow began falling in the small hours, soundless and persistent as forgotten memories.",
            "'Look how quickly the tracks disappear,' whispered Helena, watching the white mantle gather.",
            "'A traveler who looks back in the storm,' said the guide, 'soon forgets the shape of the horizon.'",
            "They drew their heavy wool mantles tight against the creeping cold that penetrated bone and sinew.",
            "In the deep distance, wolves called once, their mournful cries swallowed by the falling flakes.",
        ]),
        ("IV", [
            "At dawn, the great river appeared before them, vast and grey beneath the clearing sky.",
            "'We have crossed the boundary of our fathers,' Julian whispered, gazing upon the opposite shore.",
            "'There are no fathers on this side of the water,' Helena said, 'only the beginning of our work.'",
            "The boatman took their coins without speaking, gesturing toward the ice-laden wooden skiff.",
            "They stepped aboard together, leaving their horses in the keeping of the silent steppe.",
        ]),
    ]

    p_num = 4
    refrain = "And the river flowed onward, silent and indifferent."
    for r_num, dialogue_lines in novel_chapters:
        p = doc.new_page(width=width, height=height)
        # Roman numeral chapter header
        p.insert_text((295, 100), r_num, fontsize=16)
        y = 160
        for line in dialogue_lines:
            p.insert_text((72, y), line, fontsize=10)
            y += 28

        # Recurring refrain at the bottom of the chapter
        p.insert_text((140, 620), refrain, fontsize=10)
        p.insert_text((295, 740), str(p_num), fontsize=10)
        p_num += 1

    doc.save(str(path))
    doc.close()
    print(f"Generated: {path} ({path.stat().st_size:,} bytes)")
    return path


def generate_book_2c_multilingual():
    """
    Book 2C — Non-English Book:
    - French/German accented prose with guillemets « ... » and German quotes „ ... “
    - Hindi Devanagari text with । danda sentence endings
    """
    path = OUTPUT_DIR / "book_2c_multilingual.pdf"
    doc = fitz.open()
    width, height = 612, 792

    # Page 1: Title
    p1 = doc.new_page(width=width, height=height)
    p1.insert_text((160, 260), "ESSAIS SUR LA CONSCIENCE ET LE LANGAGE", fontsize=15)
    p1.insert_text((170, 300), "PHILOSOPHISCHE UNTERSUCHUNGEN ZUR SPRACHE", fontsize=12)
    p1.insert_text((220, 500), "ÉDITIONS DU DIALOGUE, PARIS", fontsize=10)

    # Page 2: French Chapter
    p2 = doc.new_page(width=width, height=height)
    p2.insert_text((72, 80), "CHAPITRE PREMIER: LA MÉMOIRE DU TEMPS", fontsize=13)
    french_lines = [
        "« La mémoire est le miroir où notre cœur se regarde », écrivait jadis un poète solitaire.",
        "Dans l'analyse des phénomènes conscients, la durée bergsonienne s'oppose au temps spatialisé des horloges.",
        "Nous ne vivons point dans des instants discrets, mais dans une continuité fluide et insaisissable.",
        "Chaque perception nouvelle réveille une infinité d'échos enfouis dans les replis de notre passé.",
        "Ainsi, la subjectivité se définit précisément par cette capacité d'intégrer le souvenir dans l'action présente.",
    ]
    y = 130
    for line in french_lines:
        p2.insert_text((72, y), line, fontsize=10)
        y += 26
    p2.insert_text((295, 740), "1", fontsize=10)

    # Page 3: German Chapter
    p3 = doc.new_page(width=width, height=height)
    p3.insert_text((72, 80), "KAPITEL II: DIE GRENZEN DER SPRACHE", fontsize=13)
    german_lines = [
        "„Die Grenzen meiner Sprache bedeuten die Grenzen meiner Welt“, formulierte Ludwig Wittgenstein.",
        "Jeder Gedanke bedarf eines strukturierten Zeichensystems, um überhaupt Bestimmtheit zu erlangen.",
        "Ohne die begriffliche Ordnung bliebe die Anschauung bloß ein verworrener Strom unbestimmter Eindrücke.",
        "Die philosophische Kritik muss daher zuallererst eine Kritik der sprachlichen Werkzeuge sein.",
        "Erst durch die Klärung der Grammatik lüften sich die scheinbaren Rätsel der traditionellen Metaphysik.",
    ]
    y = 130
    for line in german_lines:
        p3.insert_text((72, y), line, fontsize=10)
        y += 26
    p3.insert_text((295, 740), "2", fontsize=10)

    # Page 4: Hindi Devanagari Chapter
    # Note: PyMuPDF default Helvetica does not contain Devanagari glyphs.
    # To render Devanagari cleanly in PyMuPDF without requiring a local ttf font,
    # we can use fitz.Font("figo") or insert UTF-8 text with a fallback, or insert text.
    p4 = doc.new_page(width=width, height=height)
    p4.insert_text((72, 80), "CHAPTER III: HINDI PHILOSOPHICAL TRADITIONS", fontsize=13)
    hindi_intro = [
        "The classical Indian philosophical tradition places epistemology at the core of liberation.",
        "The concept of Pramana signifies the valid means through which authentic knowledge is acquired.",
    ]
    y = 130
    for line in hindi_intro:
        p4.insert_text((72, y), line, fontsize=10)
        y += 24

    # Let's insert Devanagari sentences. PyMuPDF supports Devanagari if a font is available,
    # or we can test Devanagari Unicode preservation in canonical extraction.
    try:
        # Check if pymupdf has built-in CJK/Devanagari font or write with fontname
        devanagari_sample = "ज्ञान ही मनुष्य का सच्चा प्रकाश है। जब अज्ञान का अंधकार छा जाता है, तब केवल सत्य ही मार्गदर्शन करता है।"
        p4.insert_text((72, y), devanagari_sample, fontsize=10)
    except Exception:
        p4.insert_text((72, y), "Jnana is the true light of humanity. Truth guides through the dark.", fontsize=10)

    p4.insert_text((295, 740), "3", fontsize=10)

    doc.save(str(path))
    doc.close()
    print(f"Generated: {path} ({path.stat().st_size:,} bytes)")
    return path


def generate_book_3a_stress_unseen():
    """
    Book 3A — Randomized Unseen Stress Book:
    - Random page counts (28 pages)
    - Random Roman-to-Arabic offset (pages i-vi, then Arabic 1..22)
    - Mixed 1 and 2 column pages
    - Alternating odd/even headers
    - Footnotes on random pages
    - TOC on page 3 linking to later pages
    - Index at the end
    """
    path = OUTPUT_DIR / "book_3a_stress_unseen.pdf"
    doc = fitz.open()
    width, height = 612, 792
    random.seed(42)

    total_pages = 28
    roman_count = 6  # Pages 1-6 are front matter (i to vi)
    body_count = total_pages - roman_count  # 22 pages (1 to 22)

    # Page 1: Title
    p1 = doc.new_page(width=width, height=height)
    p1.insert_text((150, 300), "DYNAMICS OF UNFORESEEN ADAPTATION", fontsize=16)
    p1.insert_text((190, 340), "A Comprehensive Empirical Inquiry", fontsize=11)
    p1.insert_text((250, 600), "Oxford University Press", fontsize=10)

    # Page 2: Copyright
    p2 = doc.new_page(width=width, height=height)
    p2.insert_text((72, 500), "Copyright © 2025 by Empirical Press", fontsize=9)
    p2.insert_text((72, 520), "All rights reserved. Printed in Great Britain.", fontsize=9)

    # Page 3: TOC
    p3 = doc.new_page(width=width, height=height)
    p3.insert_text((240, 80), "TABLE OF CONTENTS", fontsize=14)
    toc_entries = [
        ("Preface and Acknowledgments", "v"),
        ("Section 1: Stochastic Fluctuations in Complex Systems", "1"),
        ("Section 2: Non-Linear Bifurcations and Critical Transitions", "6"),
        ("Section 3: Information Transfer in Coupled Networks", "11"),
        ("Section 4: Evolutionary Constraints on Organizational Stability", "16"),
        ("Concluding Synthetic Perspectives", "20"),
        ("Analytical Index", "22"),
    ]
    y = 130
    for title, pnum in toc_entries:
        p3.insert_text((72, y), title, fontsize=10)
        p3.insert_text((500, y), pnum, fontsize=10)
        y += 35
    p3.insert_text((295, 740), "iii", fontsize=10)

    # Page 4: Blank/Matter
    p4 = doc.new_page(width=width, height=height)
    p4.insert_text((200, 380), "Dedicated to open scientific inquiry.", fontsize=10)
    p4.insert_text((295, 740), "iv", fontsize=10)

    # Pages 5-6: Preface (Roman v, vi)
    for pref_i, r_num in enumerate(["v", "vi"]):
        p = doc.new_page(width=width, height=height)
        y = 80
        if pref_i == 0:
            p.insert_text((72, y), "PREFACE", fontsize=14)
            y += 40
        pref_text = [
            "This volume investigates the capacity of autonomous systems to survive unexpected structural stressors.",
            "Traditional stability analyses assume bounded perturbations around known equilibrium manifolds.",
            "In real ecological and socio-technological networks, however, shocks frequently exceed pre-calibrated limits.",
            "We construct an empirical methodology capable of tracking resilience across distributed nodes.",
        ]
        for line in pref_text:
            p.insert_text((72, y), line, fontsize=10)
            y += 24
        p.insert_text((295, 740), r_num, fontsize=10)

    # Pages 7-28: Body Matter (Arabic pages 1 to 22)
    body_sections = [
        ("Section 1: Stochastic Fluctuations in Complex Systems", 5),
        ("Section 2: Non-Linear Bifurcations and Critical Transitions", 5),
        ("Section 3: Information Transfer in Coupled Networks", 5),
        ("Section 4: Evolutionary Constraints on Organizational Stability", 4),
        ("Concluding Synthetic Perspectives", 2),
    ]

    p_arabic = 1
    sec_idx = 0
    pages_left_in_sec = body_sections[0][1]

    while p_arabic <= 21:
        p = doc.new_page(width=width, height=height)
        is_even = (p_arabic % 2 == 0)

        # Running header: even = book title, odd = section title
        sec_title = body_sections[sec_idx][0]
        header = "DYNAMICS OF UNFORESEEN ADAPTATION" if is_even else sec_title.split(":")[0].strip()
        p.insert_text((72 if is_even else 360, 40), header, fontsize=8)

        y = 80
        if pages_left_in_sec == body_sections[sec_idx][1]:
            p.insert_text((72, y), sec_title, fontsize=12)
            y += 35

        # Randomly choose 1-column vs 2-column layout for variety
        is_2col = (p_arabic % 3 == 0)
        sample_prose = [
            "Dynamical systems subjected to random white noise demonstrate state-switching behavior near tipping points.",
            "Early warning indicators such as critical slowing down can be detected through autocorrelation increases.",
            "When the variance of spatial fluctuations spikes, the resilience of the current basin of attraction degrades.",
            "Empirical observations from ecological populations confirm theoretical models with high fidelity.",
            "We conclude that decentralized feedback loops provide far superior stability compared to rigid hierarchies.",
        ]

        if not is_2col:
            for line in sample_prose:
                p.insert_text((72, y), line, fontsize=10)
                y += 24
        else:
            col1_y = y
            for line in sample_prose[:3]:
                p.insert_text((72, col1_y), line, fontsize=8)
                col1_y += 22
            col2_y = y
            for line in sample_prose[3:]:
                p.insert_text((310, col2_y), line, fontsize=8)
                col2_y += 22

        # Randomly place footnote on some pages (top >= 620 pt)
        if p_arabic % 4 == 2:
            fn_y = 650
            p.insert_text((72, fn_y), f"1. Mathematical formulation of autocorrelation decay on page {p_arabic}.", fontsize=8)
            p.insert_text((72, fn_y + 14), "   Consult Appendix for detailed covariance derivation.", fontsize=8)

        p.insert_text((295, 740), str(p_arabic), fontsize=10)
        p_arabic += 1
        pages_left_in_sec -= 1
        if pages_left_in_sec == 0 and sec_idx + 1 < len(body_sections):
            sec_idx += 1
            pages_left_in_sec = body_sections[sec_idx][1]

    # Final Page (Page 28 / Arabic 22): Index
    p_last = doc.new_page(width=width, height=height)
    p_last.insert_text((72, 70), "ANALYTICAL INDEX", fontsize=14)
    index_items = [
        "Autocorrelation, 2, 7, 14",
        "Basin of attraction, 4, 9, 18",
        "Bifurcation theory, 6, 8, 15",
        "Critical slowing down, 3, 11, 16",
        "Decentralized feedback, 5, 12, 19",
        "Ergodicity, 1, 10, 20",
        "Stochastic resonance, 7, 13, 21",
    ]
    y_idx = 110
    for item in index_items:
        p_last.insert_text((72, y_idx), item, fontsize=9)
        y_idx += 22
    p_last.insert_text((295, 740), "22", fontsize=10)

    doc.save(str(path))
    doc.close()
    print(f"Generated: {path} ({path.stat().st_size:,} bytes)")
    return path


def main():
    print("=" * 70)
    print(" GENERATING ADVERSARIAL TEST BOOKS (ROUNDS 1, 2, 3)")
    print("=" * 70)
    print("\n--- ROUND 1 ---")
    generate_book_1a_messy_ocr_seminar()
    generate_book_1b_trade_nonfiction()
    generate_book_1c_trade_epub()

    print("\n--- ROUND 2 ---")
    generate_book_2a_skewed_academic()
    generate_book_2b_classic_novel()
    generate_book_2c_multilingual()

    print("\n--- ROUND 3 ---")
    generate_book_3a_stress_unseen()
    print("\nAdversarial books generated successfully in:", OUTPUT_DIR)


if __name__ == "__main__":
    main()
