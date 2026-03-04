# LibreOffice MCP Server - Product Requirements Document

**Status**: Draft
**Created**: 2026-03-04
**Owner**: Infinite Room Labs
**Slack Thread**: https://infinite-room-labs.slack.com/archives/C0AHSSUD090/p1772593380565029

## Executive Summary

Build an MCP (Model Context Protocol) server that enables AI assistants to interact with LibreOffice applications (Writer, Calc, Impress, Draw, etc.) through a standardized protocol. The server will support document creation, editing, formatting, data manipulation, and potentially extend into LibreOffice extensions for bidirectional live communication.

## Problem Statement

LibreOffice is a powerful open-source office suite, but AI assistants lack a standardized way to interact with it programmatically. Users want to:

- Generate and edit documents, spreadsheets, and presentations through conversational AI
- Automate complex document workflows
- Extract, analyze, and transform data from office documents
- Create rich formatted content without manual intervention
- Receive live updates and notifications from LibreOffice during long-running operations

Current solutions are fragmented (Python UNO bridge, command-line tools, direct file manipulation) and don't integrate well with modern AI assistant workflows.

## Goals

### Primary Goals

1. **Enable Document Manipulation**: AI assistants can create, read, update, and delete LibreOffice documents through MCP tools
2. **Support All Major Applications**: Writer (documents), Calc (spreadsheets), Impress (presentations), Draw (graphics)
3. **Provide Rich Formatting**: Support styles, templates, tables, images, charts, and complex layouts
4. **Enable Live Communication**: LibreOffice extensions that push notifications and status updates back to the MCP server
5. **Maintain Open Source Principles**: Fully open-source implementation compatible with LibreOffice's licensing

### Secondary Goals

- Document format conversion (ODT ↔ DOCX, ODS ↔ XLSX, etc.)
- Batch operations and automation
- Template management and reuse
- Macro execution and custom scripting
- Integration with other MCP servers (filesystem, database, etc.)

## Non-Goals

- Replacing LibreOffice's UI entirely
- Real-time collaborative editing (Google Docs-style)
- Cloud hosting of LibreOffice instances (out of scope for v1)
- Supporting proprietary Microsoft formats as primary targets

## User Stories

### As an AI User

- I want to generate formatted business reports from conversational prompts
- I want to create multi-sheet Excel-compatible spreadsheets with formulas and charts
- I want to build presentation decks with custom templates and layouts
- I want to extract data from existing documents for analysis
- I want to batch-convert documents between formats
- I want real-time feedback when LibreOffice is processing large operations

### As a Developer

- I want a well-documented MCP server with clear tool definitions
- I want to extend the server with custom LibreOffice macros
- I want to package this as a portable service (Docker, systemd, etc.)
- I want to integrate LibreOffice capabilities into larger automation workflows

## Technical Approach

### Architecture Options

**Option A: UNO Bridge (Python/Java)**
- Use LibreOffice's Universal Network Objects (UNO) API
- Python-UNO is mature and well-documented
- Requires LibreOffice installed and headless mode
- Pros: Full API access, official support
- Cons: Complex API, requires LibreOffice runtime

**Option B: LibreOffice Kit (C/C++)**
- Lower-level C++ library for embedding LibreOffice
- Used by Collabora Online and other projects
- Pros: Better performance, embedding support
- Cons: More complex, C++ required

**Option C: Command-line + File Manipulation**
- Use `soffice --headless` for conversions
- Direct ODT/ODS file manipulation (they're ZIP archives with XML)
- Pros: Simplest to start, no API learning curve
- Cons: Limited capabilities, fragile

**Recommendation**: Start with **Option A (Python-UNO)** for v1, with extensibility hooks to add LibreOffice Kit if needed.

### MCP Server Design

**Core Components**:

1. **MCP Server Process**: Node.js or Python-based MCP server implementation
2. **LibreOffice Bridge**: Python-UNO adapter translating MCP tool calls to UNO API calls
3. **Document Manager**: Handles document lifecycle, caching, and temporary files
4. **Extension Interface**: Optional LibreOffice extension for live notifications

**MCP Tools** (initial set):

```typescript
// Writer (Document) Tools
mcp_tools:
  - libreoffice_writer_create
  - libreoffice_writer_open
  - libreoffice_writer_insert_text
  - libreoffice_writer_apply_style
  - libreoffice_writer_insert_table
  - libreoffice_writer_insert_image
  - libreoffice_writer_export

// Calc (Spreadsheet) Tools
  - libreoffice_calc_create
  - libreoffice_calc_open
  - libreoffice_calc_set_cell
  - libreoffice_calc_get_range
  - libreoffice_calc_insert_formula
  - libreoffice_calc_create_chart
  - libreoffice_calc_export

// Impress (Presentation) Tools
  - libreoffice_impress_create
  - libreoffice_impress_open
  - libreoffice_impress_add_slide
  - libreoffice_impress_insert_text_box
  - libreoffice_impress_apply_template
  - libreoffice_impress_export

// Common Tools
  - libreoffice_convert_format
  - libreoffice_list_templates
  - libreoffice_get_status
```

### LibreOffice Extension for Live Communication

**Purpose**: Enable LibreOffice to push events back to the MCP server during long operations.

**Implementation**:
- Basic extension (Python or Java)
- Registers event listeners for document events
- Sends webhooks/HTTP callbacks to MCP server
- Packaging as `.oxt` file

**Events to Monitor**:
- Document save/load progress
- Export/conversion progress
- Error conditions
- User interactions (if running in GUI mode)

## Technical Requirements

### Functional Requirements

1. **Document Creation**: Create new Writer, Calc, Impress documents from scratch
2. **Document Editing**: Insert, update, delete content with proper formatting
3. **Format Support**: Native ODF formats + export to PDF, DOCX, XLSX, PPTX
4. **Template Support**: Apply and customize LibreOffice templates
5. **Rich Content**: Tables, images, charts, styles, page layouts
6. **Batch Operations**: Process multiple documents in sequence
7. **Error Handling**: Graceful failures with clear error messages
8. **Live Status**: Progress updates for long-running operations

### Non-Functional Requirements

1. **Performance**: Handle documents up to 100 pages / 10MB without timeout
2. **Reliability**: Crash isolation - LibreOffice crashes don't kill MCP server
3. **Security**: Sandbox LibreOffice processes, validate file paths
4. **Portability**: Run on Linux, macOS, Windows (headless mode)
5. **Documentation**: Full tool documentation, examples, troubleshooting guide

### Dependencies

- LibreOffice 7.x or later (headless capable)
- Python 3.8+ with python3-uno package
- MCP SDK (TypeScript or Python)
- File system access for document I/O

## Implementation Phases

### Phase 1: MVP - Basic Document Operations
**Goal**: Prove the concept with Writer + Calc basics

- Set up MCP server skeleton
- Implement Python-UNO bridge
- Writer: create, insert text, export to PDF
- Calc: create, set cells, basic formulas
- Documentation and examples
- **Duration**: 2-3 weeks

### Phase 2: Rich Formatting & Impress
**Goal**: Add formatting capabilities and presentation support

- Writer: styles, tables, images
- Calc: charts, formatting
- Impress: create slides, templates
- Format conversion tools
- **Duration**: 2-3 weeks

### Phase 3: LibreOffice Extension & Live Communication
**Goal**: Bidirectional communication

- Build basic LibreOffice extension
- Event listener infrastructure
- Webhook/callback mechanism
- Progress tracking for exports
- **Duration**: 3-4 weeks

### Phase 4: Advanced Features
**Goal**: Production readiness

- Macro execution support
- Advanced template management
- Batch processing optimizations
- Performance tuning
- Security hardening
- **Duration**: 3-4 weeks

## Success Metrics

1. **Functionality**: All core tools work reliably across 3 major LibreOffice applications
2. **Adoption**: At least 100 GitHub stars within 3 months of public release
3. **Reliability**: <5% error rate for document operations
4. **Performance**: 95% of operations complete within 10 seconds
5. **Documentation**: Complete API docs + 10 working examples

## Open Questions & Risks

### Open Questions

1. **Headless Stability**: How stable is LibreOffice in headless mode for long-running servers?
2. **Resource Management**: How do we handle memory leaks in LibreOffice processes?
3. **Extension Distribution**: How do users install the LibreOffice extension easily?
4. **Multi-tenancy**: Can one LibreOffice instance handle multiple concurrent requests?

### Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| LibreOffice UNO API complexity | High | Start with simple operations, iterate |
| LibreOffice crashes affecting MCP server | High | Process isolation, watchdog, auto-restart |
| Poor documentation for UNO API | Medium | Use existing projects (unoconv, pyoo) as reference |
| Extension installation friction | Medium | Provide automated installer scripts |
| Cross-platform compatibility issues | Medium | Test early on all 3 major OS platforms |

## Related Work & Inspiration

- **Collabora Online**: Uses LibreOffice Kit for web-based editing
- **unoconv**: Command-line document converter using UNO
- **pyoo**: Python library for spreadsheet manipulation via UNO
- **LibreOffice Macro tutorials**: Community documentation for scripting

## Appendix

### Useful Resources

- LibreOffice UNO API docs: https://api.libreoffice.org/
- Python-UNO examples: https://wiki.documentfoundation.org/Macros/Python_Design_Guide
- MCP Protocol spec: https://modelcontextprotocol.io/
- LibreOffice Extension development: https://wiki.documentfoundation.org/Documentation/DevGuide

### Example Use Cases

**Use Case 1: Automated Report Generation**
```
User: "Create a quarterly sales report with data from sales.csv"
AI: Uses MCP to:
  1. Create new Writer document
  2. Insert title and headers
  3. Read CSV data
  4. Create Calc sheet with data
  5. Generate chart in Writer
  6. Export to PDF
```

**Use Case 2: Batch Document Conversion**
```
User: "Convert all .odt files in /docs to PDF"
AI: Uses MCP to:
  1. List files via filesystem MCP server
  2. Open each .odt with libreoffice_writer_open
  3. Export using libreoffice_writer_export
  4. Report progress via extension callbacks
```

**Use Case 3: Presentation Generation**
```
User: "Create a 5-slide pitch deck about our product"
AI: Uses MCP to:
  1. Create Impress presentation
  2. Add slides with template
  3. Insert text and images
  4. Apply consistent formatting
  5. Export to PPTX
```

---

**Next Steps**:
1. Add to `docs/plans/RESEARCH.md` for technical evaluation
2. Create proof-of-concept Python-UNO script
3. Evaluate MCP SDK (TypeScript vs Python)
4. Draft initial MCP tool schemas
