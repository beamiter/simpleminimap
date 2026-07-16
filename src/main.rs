use std::env;
use std::io::{self, BufRead, Write};

const PROTOCOL_VERSION: u32 = 1;
const MAX_WIDTH: usize = 256;
const MAX_HEIGHT: usize = 2_000;
const MAX_COLUMNS: usize = 1_000;
const MAX_GROUPS: usize = 2_000;

#[derive(Debug)]
struct SampleGroup {
    start: usize,
    end: usize,
    samples: [String; 4],
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
    fn parse(value: &str) -> Self {
        match value {
            "blocks" => Self::Blocks,
            "ascii" => Self::Ascii,
            _ => Self::Braille,
        }
    }
}

fn main() {
    let mut args = env::args().skip(1);
    if let Some(arg) = args.next() {
        match arg.as_str() {
            "--version" | "-V" => {
                println!("simpleminimap-daemon {}", env!("CARGO_PKG_VERSION"));
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
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    let mut pending: Option<RenderRequest> = None;

    writeln!(stdout, "READY\t{PROTOCOL_VERSION}").map_err(|e| e.to_string())?;
    stdout.flush().map_err(|e| e.to_string())?;

    for line_result in stdin.lock().lines() {
        let line = line_result.map_err(|e| format!("stdin read failed: {e}"))?;
        if line.is_empty() {
            continue;
        }

        let fields: Vec<&str> = line.split('\t').collect();
        let command = fields.first().copied().unwrap_or_default();
        match command {
            "B" => match parse_begin(&fields) {
                Ok(request) => pending = Some(request),
                Err((id, message)) => {
                    write_error(&mut stdout, id, &message)?;
                    pending = None;
                }
            },
            "G" => {
                if let Err((id, message)) = parse_group(&fields, pending.as_mut()) {
                    write_error(&mut stdout, id, &message)?;
                    pending = None;
                }
            }
            "E" => {
                let id = fields
                    .get(1)
                    .and_then(|s| s.parse::<u64>().ok())
                    .unwrap_or(0);
                let Some(request) = pending.take() else {
                    write_error(&mut stdout, id, "render end without a matching begin")?;
                    continue;
                };
                if request.id != id {
                    write_error(
                        &mut stdout,
                        id,
                        "render end ID does not match active request",
                    )?;
                    continue;
                }
                if request.groups.len() != request.expected_groups {
                    write_error(
                        &mut stdout,
                        id,
                        &format!(
                            "expected {} sample groups, received {}",
                            request.expected_groups,
                            request.groups.len()
                        ),
                    )?;
                    continue;
                }
                if request.groups.last().map(|group| group.end) != Some(request.source_lines) {
                    write_error(
                        &mut stdout,
                        id,
                        "sample groups must cover the complete source",
                    )?;
                    continue;
                }
                render_and_write(&mut stdout, request)?;
            }
            "P" => {
                let id = fields
                    .get(1)
                    .and_then(|s| s.parse::<u64>().ok())
                    .unwrap_or(0);
                writeln!(stdout, "PONG\t{id}\t{PROTOCOL_VERSION}").map_err(|e| e.to_string())?;
                stdout.flush().map_err(|e| e.to_string())?;
            }
            _ => {
                write_error(&mut stdout, 0, "unknown protocol command")?;
                pending = None;
            }
        }
    }

    Ok(())
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
    let style = RenderStyle::parse(fields[6]);
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
    if fields.len() != 8 {
        return Err((
            id,
            format!("sample group expects 8 fields, got {}", fields.len()),
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
        decode_field(fields[4]),
        decode_field(fields[5]),
        decode_field(fields[6]),
        decode_field(fields[7]),
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
    request.groups.push(SampleGroup {
        start,
        end,
        samples,
    });
    Ok(())
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
    for (group, text) in request.groups.iter().zip(rows.iter()) {
        writeln!(
            out,
            "R\t{}\t{}\t{}\t{}",
            request.id,
            group.start,
            group.end,
            encode_field(text)
        )
        .map_err(|e| e.to_string())?;
    }
    writeln!(out, "E\t{}", request.id).map_err(|e| e.to_string())?;
    out.flush().map_err(|e| e.to_string())?;
    Ok(())
}

fn render(request: &RenderRequest) -> Vec<String> {
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
    let scale = ((visible_columns + dot_columns - 1) / dot_columns).max(1);

    prepared
        .iter()
        .map(|sample_rows| render_row(sample_rows, request.width, scale, request.style))
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

fn render_row(samples: &[Vec<bool>], width: usize, scale: usize, style: RenderStyle) -> String {
    let mut output = String::with_capacity(width.saturating_mul(3));
    for cell in 0..width {
        let mut mask = 0u8;
        let mut density = 0usize;
        for (sample_row, sample) in samples.iter().take(4).enumerate() {
            for dot_column in 0..2 {
                let logical_dot = cell * 2 + dot_column;
                if has_ink(sample, logical_dot, scale) {
                    density += 1;
                    mask |= braille_bit(sample_row, dot_column);
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
    }
    output
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
    let mut output = Vec::with_capacity(value.len());
    for byte in value.as_bytes() {
        match *byte {
            b'%' | b'\t' | b'\r' | b'\n' => {
                output.push(b'%');
                output.push(hex_digit(*byte >> 4) as u8);
                output.push(hex_digit(*byte & 0x0f) as u8);
            }
            _ => output.push(*byte),
        }
    }
    String::from_utf8(output).expect("encoding valid UTF-8 cannot fail")
}

fn decode_field(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0usize;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            if let (Some(high), Some(low)) =
                (hex_value(bytes[index + 1]), hex_value(bytes[index + 2]))
            {
                output.push((high << 4) | low);
                index += 3;
                continue;
            }
        }
        output.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&output).into_owned()
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
            },
        ],
    };
    let rows = render(&request);
    if rows.len() != 2 || rows.iter().any(|row| row.chars().count() != 8) {
        return Err("renderer returned the wrong dimensions".to_string());
    }
    let escaped = "a%\tb\n中";
    if decode_field(&encode_field(escaped)) != escaped {
        return Err("field codec round-trip failed".to_string());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protocol_field_codec_round_trips_utf8() {
        let input = "tabs\tpercent%newline\n中文";
        assert_eq!(decode_field(&encode_field(input)), input);
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
            }],
        };
        let rows = render(&request);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].chars().count(), 12);
    }
    #[test]
    fn begin_rejects_empty_source_or_group_set() {
        let empty_source = ["B", "1", "8", "4", "80", "4", "braille", "0", "1", "1"];
        assert!(parse_begin(&empty_source).is_err());

        let empty_groups = ["B", "1", "8", "4", "80", "4", "braille", "4", "0", "1"];
        assert!(parse_begin(&empty_groups).is_err());
    }

    #[test]
    fn groups_must_be_contiguous_and_bounded() {
        let fields = ["B", "9", "8", "2", "8", "4", "braille", "8", "2", "1"];
        let mut request = parse_begin(&fields).expect("valid begin");
        let first = ["G", "9", "1", "4", "abc", "", "", ""];
        parse_group(&first, Some(&mut request)).expect("valid first group");

        let gap = ["G", "9", "6", "8", "abc", "", "", ""];
        assert!(parse_group(&gap, Some(&mut request)).is_err());

        let long = ["G", "9", "5", "8", "123456789", "", "", ""];
        assert!(parse_group(&long, Some(&mut request)).is_err());
    }
}
