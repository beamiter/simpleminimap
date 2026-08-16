use std::env;
use std::io::{self, BufRead, Write};

const PROTOCOL_VERSION: u32 = 3;
const MAX_WIDTH: usize = 256;
const MAX_HEIGHT: usize = 2_000;
const MAX_COLUMNS: usize = 1_000;
const MAX_GROUPS: usize = 2_000;
const MAX_SOURCE_LINES: usize = 100_000_000;
const MAX_PROTOCOL_LINE_BYTES: usize = 64 * 1024;

// Syntax classes a sampled line can carry, most specific first: comment,
// string/literal, keyword, type, none.  The order is also the tie-break when
// two classes contribute the same number of dots to one rendered cell -- a
// comment sharing a cell with plain code should read as a comment, because
// that is the distinction the colour exists to draw.
const CLASS_ORDER: [u8; 5] = *b"csktn";
const CLASS_NONE: u8 = b'n';

#[derive(Debug)]
struct SampleGroup {
    start: usize,
    end: usize,
    samples: [String; 4],
    // One class byte per sample line.  The frontend sends `nnnn` when syntax
    // colouring is off, so the field count never varies with the option.
    classes: [u8; 4],
}

#[derive(Debug)]
struct RenderRequest {
    id: u64,
    width: usize,
    max_columns: usize,
    tabstop: usize,
    style: RenderStyle,
    source_lines: usize,
    expected_groups: usize,
    groups: Vec<SampleGroup>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RenderStyle {
    Braille,
    Blocks,
    Ascii,
}

impl RenderStyle {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "braille" => Some(Self::Braille),
            "blocks" => Some(Self::Blocks),
            "ascii" => Some(Self::Ascii),
            _ => None,
        }
    }
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    if !args.is_empty() {
        if args.len() != 1 {
            eprintln!("simpleminimap-daemon accepts at most one argument");
            std::process::exit(2);
        }
        let arg = &args[0];
        match arg.as_str() {
            "--version" | "-V" => {
                println!("simpleminimap-daemon {}", env!("CARGO_PKG_VERSION"));
                return;
            }
            "--help" | "-h" => {
                println!(
                    "simpleminimap-daemon {}\n\n\
                     Usage: simpleminimap-daemon [--self-test|--version|--help]",
                    env!("CARGO_PKG_VERSION")
                );
                return;
            }
            "--self-test" => {
                if let Err(message) = self_test() {
                    eprintln!("self-test failed: {message}");
                    std::process::exit(1);
                }
                println!("ok");
                return;
            }
            _ => {
                eprintln!("unknown argument: {arg}");
                std::process::exit(2);
            }
        }
    }

    if let Err(error) = run() {
        eprintln!("simpleminimap-daemon: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let stdin = io::stdin();
    let mut input = stdin.lock();
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    let mut pending: Option<RenderRequest> = None;

    writeln!(stdout, "READY\t{PROTOCOL_VERSION}").map_err(|e| e.to_string())?;
    stdout.flush().map_err(|e| e.to_string())?;

    while let Some(record) = read_protocol_line(&mut input)? {
        match record {
            ProtocolLine::Valid(line) => handle_record(&line, &mut pending, &mut stdout)?,
            ProtocolLine::Invalid(message) => {
                pending = None;
                write_error(&mut stdout, 0, &message)?;
            }
        }
    }

    Ok(())
}

fn handle_record<W: Write>(
    line: &str,
    pending: &mut Option<RenderRequest>,
    out: &mut W,
) -> Result<(), String> {
    if line.is_empty() {
        return Ok(());
    }

    let fields: Vec<&str> = line.split('\t').collect();
    let command = fields.first().copied().unwrap_or_default();
    match command {
        "B" => {
            // A newer begin always wins: the frontend coalesces edits, so an
            // unfinished older request is stale by definition.
            if let Some(superseded) = pending.take() {
                write_error(out, superseded.id, "superseded by a newer request")?;
            }
            match parse_begin(&fields) {
                Ok(request) => *pending = Some(request),
                Err((id, message)) => {
                    write_error(out, id, &message)?;
                    *pending = None;
                }
            }
        }
        "G" => {
            if let Err((id, message)) = parse_group(&fields, pending.as_mut()) {
                write_error(out, id, &message)?;
                *pending = None;
            }
        }
        "E" => {
            let id = fields
                .get(1)
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(0);
            if fields.len() != 2 {
                write_error(
                    out,
                    id,
                    &format!("render end expects 2 fields, got {}", fields.len()),
                )?;
                *pending = None;
                return Ok(());
            }
            let Some(request) = pending.take() else {
                write_error(out, id, "render end without a matching begin")?;
                return Ok(());
            };
            if request.id != id {
                write_error(out, id, "render end ID does not match active request")?;
                return Ok(());
            }
            if request.groups.len() != request.expected_groups {
                write_error(
                    out,
                    id,
                    &format!(
                        "expected {} sample groups, received {}",
                        request.expected_groups,
                        request.groups.len()
                    ),
                )?;
                return Ok(());
            }
            if request.groups.last().map(|group| group.end) != Some(request.source_lines) {
                write_error(out, id, "sample groups must cover the complete source")?;
                return Ok(());
            }
            render_and_write(out, request)?;
        }
        "P" => {
            let id = match (fields.len(), fields.get(1)) {
                (2, Some(value)) => match value.parse::<u64>() {
                    Ok(id) => id,
                    Err(_) => {
                        write_error(out, 0, "invalid ping ID")?;
                        return Ok(());
                    }
                },
                _ => {
                    write_error(
                        out,
                        0,
                        &format!("ping expects 2 fields, got {}", fields.len()),
                    )?;
                    return Ok(());
                }
            };
            writeln!(out, "PONG\t{id}\t{PROTOCOL_VERSION}").map_err(|e| e.to_string())?;
            out.flush().map_err(|e| e.to_string())?;
        }
        _ => {
            write_error(out, 0, "unknown protocol command")?;
            *pending = None;
        }
    }
    Ok(())
}

enum ProtocolLine {
    Valid(String),
    Invalid(String),
}

fn read_protocol_line<R: BufRead>(reader: &mut R) -> Result<Option<ProtocolLine>, String> {
    let mut bytes = Vec::new();
    let mut too_long = false;
    let mut reached_eof = false;

    loop {
        let available = reader
            .fill_buf()
            .map_err(|error| format!("stdin read failed: {error}"))?;
        if available.is_empty() {
            reached_eof = true;
            break;
        }

        let newline = available.iter().position(|byte| *byte == b'\n');
        let consumed = newline.map_or(available.len(), |index| index + 1);
        let content_len = newline.unwrap_or(available.len());
        if !too_long {
            if bytes.len().saturating_add(content_len) > MAX_PROTOCOL_LINE_BYTES {
                bytes.clear();
                too_long = true;
            } else {
                bytes.extend_from_slice(&available[..content_len]);
            }
        }
        reader.consume(consumed);
        if newline.is_some() {
            break;
        }
    }

    if reached_eof && bytes.is_empty() && !too_long {
        return Ok(None);
    }
    if too_long {
        return Ok(Some(ProtocolLine::Invalid(format!(
            "protocol line exceeds {MAX_PROTOCOL_LINE_BYTES} bytes"
        ))));
    }
    if bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    match String::from_utf8(bytes) {
        Ok(line) => Ok(Some(ProtocolLine::Valid(line))),
        Err(_) => Ok(Some(ProtocolLine::Invalid(
            "protocol line is not valid UTF-8".to_string(),
        ))),
    }
}

fn parse_begin(fields: &[&str]) -> Result<RenderRequest, (u64, String)> {
    let id = parse_u64(fields, 1, 0, "request ID")?;
    if fields.len() != 10 {
        return Err((id, format!("begin expects 10 fields, got {}", fields.len())));
    }

    let width = parse_usize(fields, 2, id, "width")?;
    let height = parse_usize(fields, 3, id, "height")?;
    let max_columns = parse_usize(fields, 4, id, "max columns")?;
    let tabstop = parse_usize(fields, 5, id, "tabstop")?;
    let style = RenderStyle::parse(fields[6])
        .ok_or_else(|| (id, format!("unsupported render style {}", fields[6])))?;
    let source_lines = parse_usize(fields, 7, id, "source line count")?;
    let expected_groups = parse_usize(fields, 8, id, "group count")?;
    let protocol = parse_usize(fields, 9, id, "protocol version")?;

    if protocol != PROTOCOL_VERSION as usize {
        return Err((id, format!("unsupported protocol version {protocol}")));
    }
    if !(1..=MAX_WIDTH).contains(&width) {
        return Err((id, format!("width must be in 1..={MAX_WIDTH}")));
    }
    if !(1..=MAX_HEIGHT).contains(&height) {
        return Err((id, format!("height must be in 1..={MAX_HEIGHT}")));
    }
    if !(1..=MAX_COLUMNS).contains(&max_columns) {
        return Err((id, format!("max columns must be in 1..={MAX_COLUMNS}")));
    }
    if !(1..=64).contains(&tabstop) {
        return Err((id, "tabstop must be in 1..=64".to_string()));
    }
    if source_lines == 0 {
        return Err((id, "source line count must be at least 1".to_string()));
    }
    if source_lines > MAX_SOURCE_LINES {
        return Err((
            id,
            format!("source line count must not exceed {MAX_SOURCE_LINES}"),
        ));
    }
    if expected_groups == 0 || expected_groups > height || expected_groups > MAX_GROUPS {
        return Err((
            id,
            "group count must be non-zero and within render height and safety limits".to_string(),
        ));
    }

    Ok(RenderRequest {
        id,
        width,
        max_columns,
        tabstop,
        style,
        source_lines,
        expected_groups,
        groups: Vec::with_capacity(expected_groups),
    })
}

fn parse_group(fields: &[&str], pending: Option<&mut RenderRequest>) -> Result<(), (u64, String)> {
    let id = parse_u64(fields, 1, 0, "request ID")?;
    if fields.len() != 9 {
        return Err((
            id,
            format!("sample group expects 9 fields, got {}", fields.len()),
        ));
    }
    let Some(request) = pending else {
        return Err((id, "sample group without a matching begin".to_string()));
    };
    if request.id != id {
        return Err((
            id,
            "sample group ID does not match active request".to_string(),
        ));
    }
    if request.groups.len() >= request.expected_groups {
        return Err((id, "received more sample groups than declared".to_string()));
    }

    let start = parse_usize(fields, 2, id, "row start")?;
    let end = parse_usize(fields, 3, id, "row end")?;
    if start == 0 || end < start || end > request.source_lines.max(1) {
        return Err((id, "invalid source line range".to_string()));
    }

    let expected_start = request
        .groups
        .last()
        .map_or(1, |previous| previous.end.saturating_add(1));
    if start != expected_start {
        return Err((
            id,
            "source ranges must be contiguous and start at line 1".to_string(),
        ));
    }

    let samples = [
        decode_field(fields[4]).map_err(|message| (id, message))?,
        decode_field(fields[5]).map_err(|message| (id, message))?,
        decode_field(fields[6]).map_err(|message| (id, message))?,
        decode_field(fields[7]).map_err(|message| (id, message))?,
    ];
    if samples
        .iter()
        .any(|sample| sample.chars().count() > request.max_columns)
    {
        return Err((
            id,
            "sample exceeds the declared maximum column count".to_string(),
        ));
    }
    let classes = parse_classes(fields[8]).map_err(|message| (id, message))?;
    request.groups.push(SampleGroup {
        start,
        end,
        samples,
        classes,
    });
    Ok(())
}

// The class field is fixed-width and drawn from a closed alphabet, so it needs
// no escaping and no length negotiation -- reject anything else outright
// rather than silently colouring by a byte the renderer does not know.
fn parse_classes(field: &str) -> Result<[u8; 4], String> {
    let bytes = field.as_bytes();
    if bytes.len() != 4 {
        return Err("sample class field must be exactly 4 characters".to_string());
    }
    let mut classes = [CLASS_NONE; 4];
    for (slot, byte) in classes.iter_mut().zip(bytes.iter()) {
        if !CLASS_ORDER.contains(byte) {
            return Err("sample class field has an unknown class".to_string());
        }
        *slot = *byte;
    }
    Ok(classes)
}

fn parse_u64(
    fields: &[&str],
    index: usize,
    fallback_id: u64,
    name: &str,
) -> Result<u64, (u64, String)> {
    fields
        .get(index)
        .ok_or_else(|| (fallback_id, format!("missing {name}")))?
        .parse::<u64>()
        .map_err(|_| (fallback_id, format!("invalid {name}")))
}

fn parse_usize(fields: &[&str], index: usize, id: u64, name: &str) -> Result<usize, (u64, String)> {
    fields
        .get(index)
        .ok_or_else(|| (id, format!("missing {name}")))?
        .parse::<usize>()
        .map_err(|_| (id, format!("invalid {name}")))
}

struct RenderedRow {
    text: String,
    // One ASCII digit per rendered cell classifying its ink density,
    // used by the frontend for brightness shading: 0 empty, 1..3 dense.
    shade: String,
    // One class byte per rendered cell, from CLASS_ORDER: the class of the
    // sample lines that put the most ink in that cell.  Density gives the
    // frontend brightness, this gives it hue.
    classes: String,
}

fn render_and_write<W: Write>(out: &mut W, request: RenderRequest) -> Result<(), String> {
    let rows = render(&request);
    writeln!(
        out,
        "B\t{}\t{}\t{}",
        request.id,
        request.source_lines,
        rows.len()
    )
    .map_err(|e| e.to_string())?;
    for (group, row) in request.groups.iter().zip(rows.iter()) {
        writeln!(
            out,
            "R\t{}\t{}\t{}\t{}\t{}\t{}",
            request.id,
            group.start,
            group.end,
            encode_field(&row.text),
            row.shade,
            row.classes
        )
        .map_err(|e| e.to_string())?;
    }
    writeln!(out, "E\t{}", request.id).map_err(|e| e.to_string())?;
    out.flush().map_err(|e| e.to_string())?;
    Ok(())
}

fn render(request: &RenderRequest) -> Vec<RenderedRow> {
    let mut prepared: Vec<Vec<Vec<bool>>> = Vec::with_capacity(request.groups.len());
    let mut max_used = 0usize;

    for group in &request.groups {
        let mut sample_rows = Vec::with_capacity(4);
        for sample in &group.samples {
            let (occupancy, used) = line_occupancy(sample, request.max_columns, request.tabstop);
            max_used = max_used.max(used);
            sample_rows.push(occupancy);
        }
        prepared.push(sample_rows);
    }

    let dot_columns = request.width.saturating_mul(2).max(1);
    let visible_columns = max_used
        .max(dot_columns)
        .min(request.max_columns.max(dot_columns));
    let scale = visible_columns.div_ceil(dot_columns).max(1);

    prepared
        .iter()
        .zip(request.groups.iter())
        .map(|(sample_rows, group)| {
            render_row(
                sample_rows,
                &group.classes,
                request.width,
                scale,
                request.style,
            )
        })
        .collect()
}

fn line_occupancy(text: &str, max_columns: usize, tabstop: usize) -> (Vec<bool>, usize) {
    let mut occupied = vec![false; max_columns];
    let mut column = 0usize;
    let mut used = 0usize;

    for ch in text.chars() {
        if column >= max_columns {
            break;
        }
        if ch == '\t' {
            column = ((column / tabstop) + 1).saturating_mul(tabstop);
            used = used.max(column.min(max_columns));
            continue;
        }

        if !ch.is_whitespace() {
            occupied[column] = true;
            used = used.max(column + 1);
        }
        column += 1;
    }

    (occupied, used)
}

fn render_row(
    samples: &[Vec<bool>],
    classes: &[u8; 4],
    width: usize,
    scale: usize,
    style: RenderStyle,
) -> RenderedRow {
    let mut output = String::with_capacity(width.saturating_mul(3));
    let mut shade = String::with_capacity(width);
    let mut cell_classes = String::with_capacity(width);
    for cell in 0..width {
        let mut mask = 0u8;
        let mut density = 0usize;
        let mut ink_by_class = [0usize; CLASS_ORDER.len()];
        for (sample_row, sample) in samples.iter().take(4).enumerate() {
            for dot_column in 0..2 {
                let logical_dot = cell * 2 + dot_column;
                if has_ink(sample, logical_dot, scale) {
                    density += 1;
                    mask |= braille_bit(sample_row, dot_column);
                    ink_by_class[class_index(classes[sample_row])] += 1;
                }
            }
        }

        let ch = match style {
            RenderStyle::Braille => {
                if mask == 0 {
                    ' '
                } else {
                    char::from_u32(0x2800 + u32::from(mask)).unwrap_or(' ')
                }
            }
            RenderStyle::Blocks => density_glyph(density, true),
            RenderStyle::Ascii => density_glyph(density, false),
        };
        output.push(ch);
        shade.push(shade_digit(density));
        cell_classes.push(char::from(dominant_class(&ink_by_class)));
    }
    RenderedRow {
        text: output,
        shade,
        classes: cell_classes,
    }
}

fn class_index(class: u8) -> usize {
    CLASS_ORDER
        .iter()
        .position(|candidate| *candidate == class)
        .unwrap_or(CLASS_ORDER.len() - 1)
}

// An empty cell has no class at all, and a cell whose ink is all plain code is
// left to the density shading -- both report `n` so the frontend has exactly
// one rule: colour the cell when the class is not `n`, shade it otherwise.
fn dominant_class(ink_by_class: &[usize; CLASS_ORDER.len()]) -> u8 {
    let mut best = CLASS_ORDER.len() - 1;
    let mut best_ink = 0usize;
    for (index, ink) in ink_by_class.iter().enumerate() {
        if *ink > best_ink {
            best = index;
            best_ink = *ink;
        }
    }
    if best_ink == 0 {
        return CLASS_NONE;
    }
    CLASS_ORDER[best]
}

fn shade_digit(density: usize) -> char {
    match density {
        0 => '0',
        1..=2 => '1',
        3..=5 => '2',
        _ => '3',
    }
}

fn has_ink(row: &[bool], logical_dot: usize, scale: usize) -> bool {
    let start = logical_dot.saturating_mul(scale);
    if start >= row.len() {
        return false;
    }
    let end = (start + scale).min(row.len());
    row[start..end].iter().any(|value| *value)
}

fn braille_bit(row: usize, column: usize) -> u8 {
    const DOTS: [[u8; 2]; 4] = [[0x01, 0x08], [0x02, 0x10], [0x04, 0x20], [0x40, 0x80]];
    DOTS[row][column]
}

fn density_glyph(density: usize, unicode: bool) -> char {
    if unicode {
        const GLYPHS: [char; 9] = [' ', '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
        GLYPHS[density.min(8)]
    } else {
        const GLYPHS: [char; 9] = [' ', '.', ':', '-', '=', '+', '*', '#', '@'];
        GLYPHS[density.min(8)]
    }
}

fn encode_field(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '%' | '\t' | '\r' | '\n' => {
                let byte = ch as u8;
                output.push('%');
                output.push(hex_digit(byte >> 4));
                output.push(hex_digit(byte & 0x0f));
            }
            _ => output.push(ch),
        }
    }
    output
}

fn decode_field(value: &str) -> Result<String, String> {
    let bytes = value.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0usize;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            if index + 2 >= bytes.len() {
                return Err("truncated protocol field escape".to_string());
            }
            let Some(high) = hex_value(bytes[index + 1]) else {
                return Err("invalid protocol field escape".to_string());
            };
            let Some(low) = hex_value(bytes[index + 2]) else {
                return Err("invalid protocol field escape".to_string());
            };
            output.push((high << 4) | low);
            index += 3;
            continue;
        }
        output.push(bytes[index]);
        index += 1;
    }
    String::from_utf8(output).map_err(|_| "decoded protocol field is not valid UTF-8".to_string())
}

fn hex_digit(value: u8) -> char {
    match value {
        0..=9 => char::from(b'0' + value),
        _ => char::from(b'A' + (value - 10)),
    }
}

fn hex_value(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

fn write_error<W: Write>(out: &mut W, id: u64, message: &str) -> Result<(), String> {
    writeln!(out, "X\t{id}\t{}", encode_field(message)).map_err(|e| e.to_string())?;
    out.flush().map_err(|e| e.to_string())?;
    Ok(())
}

fn self_test() -> Result<(), String> {
    let request = RenderRequest {
        id: 1,
        width: 8,
        max_columns: 80,
        tabstop: 4,
        style: RenderStyle::Braille,
        source_lines: 8,
        expected_groups: 2,
        groups: vec![
            SampleGroup {
                start: 1,
                end: 4,
                samples: [
                    "fn main() {".into(),
                    "    println!(\"hello\");".into(),
                    "}".into(),
                    String::new(),
                ],
                classes: *b"ksnn",
            },
            SampleGroup {
                start: 5,
                end: 8,
                samples: [
                    "// tail".into(),
                    String::new(),
                    String::new(),
                    String::new(),
                ],
                classes: *b"cnnn",
            },
        ],
    };
    let rows = render(&request);
    if rows.len() != 2
        || rows.iter().any(|row| {
            row.text.chars().count() != 8
                || row.shade.len() != 8
                || !row.shade.bytes().all(|byte| (b'0'..=b'3').contains(&byte))
                || row.classes.len() != 8
                || !row.classes.bytes().all(|byte| CLASS_ORDER.contains(&byte))
        })
    {
        return Err("renderer returned the wrong dimensions".to_string());
    }
    let escaped = "a%\tb\n中";
    if decode_field(&encode_field(escaped)).map_err(|error| error.to_string())? != escaped {
        return Err("field codec round-trip failed".to_string());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn protocol_field_codec_round_trips_utf8() {
        let input = "tabs\tpercent%newline\n中文";
        assert_eq!(decode_field(&encode_field(input)).unwrap(), input);
        assert!(decode_field("bad%2").is_err());
        assert!(decode_field("bad%XZ").is_err());
        assert!(decode_field("%FF").is_err());
    }

    #[test]
    fn braille_bit_layout_matches_unicode_standard() {
        assert_eq!(braille_bit(0, 0), 0x01);
        assert_eq!(braille_bit(3, 0), 0x40);
        assert_eq!(braille_bit(0, 1), 0x08);
        assert_eq!(braille_bit(3, 1), 0x80);
    }

    #[test]
    fn renderer_has_stable_width() {
        let request = RenderRequest {
            id: 7,
            width: 12,
            max_columns: 120,
            tabstop: 4,
            style: RenderStyle::Braille,
            source_lines: 4,
            expected_groups: 1,
            groups: vec![SampleGroup {
                start: 1,
                end: 4,
                samples: [
                    "pub fn answer() -> usize {".into(),
                    "    42".into(),
                    "}".into(),
                    String::new(),
                ],
                classes: [b'n'; 4],
            }],
        };
        let rows = render(&request);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].text.chars().count(), 12);
        assert_eq!(rows[0].shade.len(), 12);
        assert_eq!(rows[0].classes.len(), 12);
        assert!(
            rows[0]
                .shade
                .bytes()
                .all(|byte| (b'0'..=b'3').contains(&byte))
        );
        assert!(rows[0].shade.bytes().any(|byte| byte != b'0'));
    }

    // Density says how much ink a cell has; the class says what kind.  A cell
    // fed only by a comment line has to come back `c` even though the shade
    // digit is identical to the one a plain line would have produced.
    #[test]
    fn cell_class_follows_the_sample_that_inked_it() {
        let mut request = RenderRequest {
            id: 3,
            width: 4,
            max_columns: 40,
            tabstop: 4,
            style: RenderStyle::Braille,
            source_lines: 8,
            expected_groups: 2,
            groups: Vec::new(),
        };
        // Only the first sample line carries ink, so every inked cell in row 1
        // must take that line's class and nothing else's.
        parse_group(
            &["G", "3", "1", "4", "xxxxxxxx", "", "", "", "cnnn"],
            Some(&mut request),
        )
        .expect("comment group");
        parse_group(
            &["G", "3", "5", "8", "xxxxxxxx", "", "", "", "knnn"],
            Some(&mut request),
        )
        .expect("keyword group");

        let rows = render(&request);
        assert_eq!(rows.len(), 2);
        assert!(rows[0].classes.starts_with("cccc"), "{}", rows[0].classes);
        assert!(rows[1].classes.starts_with("kkkk"), "{}", rows[1].classes);
        // Same ink, same brightness: hue is the only thing that differs.
        assert_eq!(rows[0].shade, rows[1].shade);
    }

    // An empty cell has no class to report, and a cell inked only by plain
    // code reports `n` so the frontend falls back to density shading.
    #[test]
    fn cells_without_classified_ink_report_none() {
        let mut request = RenderRequest {
            id: 4,
            width: 6,
            max_columns: 40,
            tabstop: 4,
            style: RenderStyle::Braille,
            source_lines: 4,
            expected_groups: 1,
            groups: Vec::new(),
        };
        parse_group(
            &["G", "4", "1", "4", "xx", "", "", "", "cnnn"],
            Some(&mut request),
        )
        .expect("valid group");
        let rows = render(&request);
        assert!(rows[0].classes.starts_with('c'));
        assert!(rows[0].classes.ends_with("nnnn"));
    }

    #[test]
    fn group_rejects_a_malformed_class_field() {
        let fields = ["B", "5", "8", "2", "8", "4", "braille", "8", "1", "3"];
        let mut request = parse_begin(&fields).expect("valid begin");
        let short = ["G", "5", "1", "8", "abc", "", "", "", "cnn"];
        assert!(parse_group(&short, Some(&mut request)).is_err());
        let unknown = ["G", "5", "1", "8", "abc", "", "", "", "cnnz"];
        assert!(parse_group(&unknown, Some(&mut request)).is_err());
        let missing = ["G", "5", "1", "8", "abc", "", "", ""];
        assert!(parse_group(&missing, Some(&mut request)).is_err());
    }
    #[test]
    fn begin_rejects_empty_source_or_group_set() {
        let empty_source = ["B", "1", "8", "4", "80", "4", "braille", "0", "1", "3"];
        assert!(parse_begin(&empty_source).is_err());

        let empty_groups = ["B", "1", "8", "4", "80", "4", "braille", "4", "0", "3"];
        assert!(parse_begin(&empty_groups).is_err());

        let bad_style = ["B", "1", "8", "4", "80", "4", "pixels", "4", "1", "3"];
        assert!(parse_begin(&bad_style).is_err());

        let old_protocol = ["B", "1", "8", "4", "80", "4", "braille", "4", "1", "2"];
        assert!(parse_begin(&old_protocol).is_err());
    }

    #[test]
    fn groups_must_be_contiguous_and_bounded() {
        let fields = ["B", "9", "8", "2", "8", "4", "braille", "8", "2", "3"];
        let mut request = parse_begin(&fields).expect("valid begin");
        let first = ["G", "9", "1", "4", "abc", "", "", "", "nnnn"];
        parse_group(&first, Some(&mut request)).expect("valid first group");

        let gap = ["G", "9", "6", "8", "abc", "", "", "", "nnnn"];
        assert!(parse_group(&gap, Some(&mut request)).is_err());

        let long = ["G", "9", "5", "8", "123456789", "", "", "", "nnnn"];
        assert!(parse_group(&long, Some(&mut request)).is_err());
    }

    #[test]
    fn begin_preempts_an_active_request() {
        let mut pending: Option<RenderRequest> = None;
        let mut out: Vec<u8> = Vec::new();
        handle_record(
            "B\t1\t8\t4\t80\t4\tbraille\t4\t1\t3",
            &mut pending,
            &mut out,
        )
        .unwrap();
        handle_record(
            "B\t2\t8\t4\t80\t4\tbraille\t4\t1\t3",
            &mut pending,
            &mut out,
        )
        .unwrap();
        handle_record("G\t2\t1\t4\tfn main()\t\t\t\tnnnn", &mut pending, &mut out).unwrap();
        handle_record("E\t2", &mut pending, &mut out).unwrap();

        let output = String::from_utf8(out).unwrap();
        assert!(output.contains("X\t1\tsuperseded by a newer request"));
        assert!(output.contains("B\t2\t4\t1"));
        assert!(output.ends_with("E\t2\n"));
        assert!(pending.is_none());
    }

    #[test]
    fn bounded_protocol_reader_recovers_after_an_oversized_line() {
        let mut input = vec![b'x'; MAX_PROTOCOL_LINE_BYTES + 1];
        input.extend_from_slice(b"\nP\t7\r\n");
        let mut cursor = Cursor::new(input);

        match read_protocol_line(&mut cursor).unwrap() {
            Some(ProtocolLine::Invalid(message)) => assert!(message.contains("exceeds")),
            _ => panic!("oversized line should be rejected"),
        }
        match read_protocol_line(&mut cursor).unwrap() {
            Some(ProtocolLine::Valid(line)) => assert_eq!(line, "P\t7"),
            _ => panic!("reader should recover at the next line boundary"),
        }
        assert!(read_protocol_line(&mut cursor).unwrap().is_none());
    }

    #[test]
    fn occupancy_expands_tabs_and_clips_to_the_declared_width() {
        let (occupied, used) = line_occupancy("\tX", 6, 4);
        assert_eq!(occupied, [false, false, false, false, true, false]);
        assert_eq!(used, 5);

        let (clipped, used) = line_occupancy("123456789", 4, 4);
        assert_eq!(clipped, [true, true, true, true]);
        assert_eq!(used, 4);
    }
}
