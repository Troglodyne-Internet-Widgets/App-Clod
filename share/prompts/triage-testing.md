Each spoke run is told the text between the markers below, in its system
prompt. It comes from the configuration of this bot, not from GitHub.

<<<SPOKE_PROMPT
{{spoke_prompt}}
SPOKE_PROMPT>>>

Write how to test the change into the `instructions` of each repository, and
make it agree with that text.

Each spoke run also gets its own checkout of these tool spokes, so that it can
run their tools: {{tool_spokes}}. If a tool spoke must change before another
spoke can test its change, for example because the test needs a new recipe,
the scope is `multi`. Put the tool spoke first in `order`, and say in the
`instructions` of the spoke that depends on it that its pull request needs the
pull request of the tool spoke. The checkout of the tool spoke in that later
run is then at the branch of the earlier one.
