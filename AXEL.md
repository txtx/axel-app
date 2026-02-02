---
workspace: axel-apple

# =============================================================================
# Skill directories
# =============================================================================
# Search paths for skill files (first match wins for duplicate names)
# Supports: ./relative, ~/home, /absolute paths

skills:
  - path: ./skills
  - path: ~/.config/axel/skills

# =============================================================================
# Layouts
# =============================================================================

layouts:
  # ---------------------------------------------------------------------------
  # Pane definitions
  # ---------------------------------------------------------------------------
  # Define panes that can be used in grid layouts
  #
  # Built-in types: claude, codex, opencode, antigravity, shell
  # Custom types use the 'command' field

  panes:
    # Claude Code - AI coding assistant
    - type: claude
      color: gray
      skills:
        - "*"                    # Load all skills, or list specific: ["skill1", "skill2"]
      # model: sonnet            # Model: sonnet, opus, haiku
      # prompt: "Your task..."   # Initial prompt
      # allowed_tools: []        # Restrict to specific tools
      # disallowed_tools: []     # Block specific tools
      # args: []                 # Additional CLI arguments

    # Codex - OpenAI coding assistant
    - type: codex
      color: green

    # OpenCode - Open-source coding assistant
    # - type: opencode
    #   color: blue
    #   skills: ["*"]

    # Antigravity - Google coding assistant
    # - type: antigravity
    #   color: orange
    #   skills: ["*"]
    #   # model: gemini-3-pro    # Model to use

    # Regular shell with notes displayed on startup
    - type: shell
      notes:
        - "$ axel -k axel-apple"

    # Custom command example
    # - type: logs
    #   command: "tail -f /var/log/app.log"
    #   color: red

  # ---------------------------------------------------------------------------
  # Grid layouts
  # ---------------------------------------------------------------------------
  # Layout configurations for tmux sessions
  #
  # Grid types:
  #   tmux    - Standard tmux session (default)
  #   tmux_cc - iTerm2 tmux integration mode
  #   shell   - No tmux, run first pane directly
  #
  # Cell positioning:
  #   col: 0, 1, 2...  - Column position (left to right)
  #   row: 0, 1, 2...  - Row position within column (top to bottom)
  #   width: 50        - Column width percentage
  #   height: 30       - Row height percentage
  #
  # Colors: purple, yellow, red, green, blue, gray, orange

  grids:
    # Default grid - two columns
    default:
      type: tmux
      claude:
        col: 0
        row: 0
      shell:
        col: 1
        row: 0
        color: yellow

    # Solo mode - single AI pane
    # solo:
    #   type: shell
    #   claude:
    #     col: 0
    #     row: 0

    # Three column layout
    # wide:
    #   type: tmux
    #   claude:
    #     col: 0
    #     row: 0
    #     width: 40
    #   codex:
    #     col: 1
    #     row: 0
    #     width: 40
    #   shell:
    #     col: 2
    #     row: 0
    #     width: 20
---

# axel-apple

Axel workspace configuration. The YAML frontmatter above defines the workspace layout.

- Launch: `axel`
- Launch with profile: `axel --profile <name>`
- Kill session: `axel -k axel-apple`

See [docs.axel.md](https://docs.axel.md) for full configuration reference.
