import pytest
from app.services.edge_ai import evaluate_card_novelty


def test_novelty_gate_blocks_banned_generic_phrases():
    chunk = (
        "At dawn, when you have trouble getting out of bed, tell yourself: "
        "'I have to go to work—as a human being. What do I have to complain of, "
        "if I'm going to do what I was born for?'"
    )
    title = "Duty in Stoicism"
    
    # 1. "In this passage"
    body_slop1 = (
        "In this passage, the author highlights the importance of morning discipline "
        "and reminds the reader that humans are built to contribute."
    )
    res1 = evaluate_card_novelty(chunk, title, body_slop1)
    assert res1["passed"] is False
    assert "banned generic slop phrase" in res1["reason"].lower()

    # 2. "The author explains"
    body_slop2 = (
        "The author explains how Roman soldiers rose early in 172 AD during military campaigns."
    )
    res2 = evaluate_card_novelty(chunk, title, body_slop2)
    assert res2["passed"] is False
    assert "banned generic slop phrase" in res2["reason"].lower()


def test_novelty_gate_blocks_insufficient_external_entities():
    chunk = (
        "At dawn, when you have trouble getting out of bed, tell yourself: "
        "'I have to go to work—as a human being. What do I have to complain of, "
        "if I'm going to do what I was born for?'"
    )
    title = "Marcus Aurelius on Duty"
    # Merely paraphrases with 0-1 new entities
    body_low_novelty = (
        "Morning duty requires overcoming bodily inertia to pursue one's true vocation."
    )
    res = evaluate_card_novelty(chunk, title, body_low_novelty)
    assert res["passed"] is False
    assert res["new_entity_count"] < 2
    assert "insufficient novel external anchors" in res["reason"].lower()


def test_novelty_gate_blocks_echo_similarity():
    chunk = (
        "Researchers in 1978 discovered that lottery winners returned to baseline happiness."
    )
    title = "Hedonic Treadmill"
    # Verbatim repeating chunk
    body_echo = (
        "Researchers in 1978 discovered that lottery winners returned to baseline happiness."
    )
    res = evaluate_card_novelty(chunk, title, body_echo)
    assert res["passed"] is False
    # Either echo_similarity > 0.81 or new_entity_count == 0
    assert res["echo_similarity"] > 0.81 or res["new_entity_count"] < 2


def test_novelty_gate_accepts_high_surprise_cards():
    # Example 1: Marcus Aurelius Meditations
    chunk_marcus = (
        "At dawn, when you have trouble getting out of bed, tell yourself: "
        "'I have to go to work—as a human being. What do I have to complain of, "
        "if I'm going to do what I was born for?'"
    )
    title_marcus = "HISTORICAL CONTEXT: Written Inside a Frozen Danube War Tent"
    body_marcus = (
        "Marcus Aurelius did not write this in a Roman palace—he wrote Book 5 around 172 AD "
        "inside a freezing military camp at Carnuntum along the Danube River during the "
        "Marcomannic Wars, while suffering from chronic stomach ulcers and chest pains "
        "documented by his personal physician, Galen of Pergamon."
    )
    res_marcus = evaluate_card_novelty(chunk_marcus, title_marcus, body_marcus)
    assert res_marcus["passed"] is True, f"Failed with: {res_marcus['reason']}"
    assert res_marcus["new_entity_count"] >= 2
    assert res_marcus["echo_similarity"] <= 0.81

    # Example 2: Mark Manson Subtle Art
    chunk_manson = (
        "A 1970s study compared lottery winners and paraplegics and found that after a year, "
        "both groups returned to the same baseline level of happiness."
    )
    title_manson = "EMPIRICAL STUDY: The 22-Person Study That Misled Psychology"
    body_manson = (
        "Wait—did Brickman's 1978 happiness study actually hold up when tested on thousands of people?"
        "||REVEAL||Brickman, Coates, and Janoff-Bulman's original 1978 Northwestern study only surveyed "
        "22 lottery winners and 29 paralysis patients. When economists Erik Lindqvist and Robert Östling "
        "tracked 3,362 Swedish lottery winners over 5 to 22 years (Review of Economic Studies, 2020), "
        "they found large windfalls caused a permanent, non-fading increase in overall life satisfaction."
    )
    res_manson = evaluate_card_novelty(chunk_manson, title_manson, body_manson)
    assert res_manson["passed"] is True, f"Failed with: {res_manson['reason']}"
    assert res_manson["new_entity_count"] >= 2
    assert res_manson["echo_similarity"] <= 0.81
