"""MCP server that renders Mule flow XML inline in Claude Desktop.

Pairs with the build-headless-integration skill: after the skill writes
`<projectDir>/src/main/mule/<name>.xml`, the agent calls the
`render_mule_flow` tool and Claude Desktop renders an interactive
React Flow canvas in the chat.

Entry point:
    build_headless_integration_mcp.server:main
"""

__version__ = "0.1.0"
