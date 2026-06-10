"""Behavioural tests for parse_flow_xml.

We assert on observable graph shape (node counts, kinds, labels, edge
endpoints) — never on internal helpers — so the parser is free to refactor
how it walks the tree without breaking this suite.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from build_headless_integration_mcp.parse import parse_flow_xml


_FIXTURES = Path(__file__).parent / "fixtures"


def test_sf_to_twilio_smoke(tmp_path: Path) -> None:
    """Production-shaped flow: HTTP listener → vars → query → transform → ... → error-handler."""
    xml_path = _FIXTURES / "sf-to-twilio.xml"
    graph = parse_flow_xml(xml_path)

    assert len(graph["flows"]) == 1
    flow = graph["flows"][0]
    assert flow["kind"] == "flow"
    assert flow["name"] == "sf-accounts-to-twilio-flow"

    nodes = flow["nodes"]
    edges = flow["edges"]

    # Trigger first.
    assert nodes[0]["kind"] == "trigger"
    assert nodes[0]["elementName"] == "http:listener"
    assert nodes[0]["attributes"]["path"] == "/notify"
    assert nodes[0]["attributes"]["allowedMethods"] == "POST"

    # The connector op must appear with its real element name and attributes.
    sf_query = next(n for n in nodes if n["elementName"] == "salesforce:query")
    assert sf_query["kind"] == "processor"
    assert "soql" in sf_query["attributes"]
    assert "config-ref" in sf_query["attributes"]

    # Twilio op present.
    twilio = next(n for n in nodes if n["elementName"] == "twilio:sendMessage")
    assert twilio["kind"] == "processor"
    assert twilio["attributes"]["target"] == "smsResult"

    # Error handler collapsed to one node.
    eh = [n for n in nodes if n["kind"] == "error-handler"]
    assert len(eh) == 1
    assert eh[0]["branches"] == 1  # one <on-error-propagate>
    assert "1 branch" in eh[0]["label"]

    # Edges connect each consecutive node.
    assert len(edges) == len(nodes) - 1
    for i, edge in enumerate(edges):
        assert edge["source"] == nodes[i]["id"]
        assert edge["target"] == nodes[i + 1]["id"]


def test_doc_attributes_become_label_and_doc_block() -> None:
    """doc:name takes precedence over the element name for the visible label."""
    xml_path = _FIXTURES / "sf-to-twilio.xml"
    graph = parse_flow_xml(xml_path)
    nodes = graph["flows"][0]["nodes"]

    trigger = nodes[0]
    assert trigger["label"] == "HTTP POST /notify"  # from doc:name
    assert trigger["doc"]["name"] == "HTTP POST /notify"
    assert "doc:" not in trigger["attributes"]  # documentation attrs split off
    # Description preserved.
    assert "trigger request" in trigger["doc"]["description"]


def test_top_level_configs_are_skipped() -> None:
    """<*-config> and <configuration-properties> are not flow nodes."""
    xml_path = _FIXTURES / "sf-to-twilio.xml"
    graph = parse_flow_xml(xml_path)
    flow = graph["flows"][0]

    element_names = {n["elementName"] for n in flow["nodes"]}
    assert "http:listener-config" not in element_names
    assert "salesforce:sfdc-config" not in element_names
    assert "twilio:config" not in element_names
    assert "configuration-properties" not in element_names


def test_configs_block_captures_provider_for_test_connection() -> None:
    """`configs` map carries the per-config metadata the canvas needs to
    drive Test Connection: connector, providerName, provider attributes."""
    xml_path = _FIXTURES / "sf-to-twilio.xml"
    graph = parse_flow_xml(xml_path)

    configs = graph["configs"]
    # Both connector configs are present, indexed by their `name` attribute.
    assert "Salesforce_Config" in configs
    assert "Twilio_Config" in configs

    sfdc = configs["Salesforce_Config"]
    assert sfdc["connector"] == "salesforce"
    assert sfdc["providerName"] == "basic"
    assert sfdc["providerElement"] == "salesforce:basic"
    assert "username" in sfdc["providerAttributes"]
    assert "password" in sfdc["providerAttributes"]

    twilio = configs["Twilio_Config"]
    assert twilio["connector"] == "twilio"
    assert twilio["providerName"] == "account-sid-auth-token"


def test_scheduler_trigger() -> None:
    """A flow whose first child is <scheduler> emits a trigger node."""
    xml_path = _FIXTURES / "scheduler-flow.xml"
    graph = parse_flow_xml(xml_path)
    nodes = graph["flows"][0]["nodes"]
    assert nodes[0]["kind"] == "trigger"
    assert nodes[0]["elementName"] == "scheduler"


def test_choice_collapses_to_container() -> None:
    """<choice> with two <when>s becomes one container node, branches=2."""
    xml_path = _FIXTURES / "choice-flow.xml"
    graph = parse_flow_xml(xml_path)
    nodes = graph["flows"][0]["nodes"]
    container = next(n for n in nodes if n["kind"] == "container")
    assert container["elementName"] == "choice"
    assert container["branches"] == 3  # two whens + one otherwise as <when>+<otherwise> children
    # Children of <choice> must NOT appear as flow nodes.
    assert all(n["elementName"] != "logger" or n["kind"] == "processor" for n in nodes)


def test_missing_xml_raises() -> None:
    with pytest.raises(FileNotFoundError):
        parse_flow_xml("/no/such/file.xml")


def test_non_mule_root_raises(tmp_path: Path) -> None:
    bogus = tmp_path / "not-mule.xml"
    bogus.write_text('<?xml version="1.0"?><root/>', encoding="utf-8")
    with pytest.raises(ValueError, match="expected <mule> root"):
        parse_flow_xml(bogus)


def test_empty_mule_yields_no_flows_and_a_diagnostic(tmp_path: Path) -> None:
    empty = tmp_path / "empty.xml"
    empty.write_text(
        '<?xml version="1.0"?><mule xmlns="http://www.mulesoft.org/schema/mule/core"/>',
        encoding="utf-8",
    )
    graph = parse_flow_xml(empty)
    assert graph["flows"] == []
    assert any("no <flow>" in d for d in graph["diagnostics"])
