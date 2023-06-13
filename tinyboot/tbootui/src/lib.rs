use ratatui::{
    backend::TermionBackend,
    widgets::{Block, Paragraph},
    Terminal,
};
use std::io::Write;
use tboot::linux::LinuxBootEntry;
use termion::{event::Key, input::TermRead};

pub fn edit<W: Write>(
    entry: LinuxBootEntry,
    terminal: &mut Terminal<TermionBackend<W>>,
) -> Option<LinuxBootEntry> {
    let stdin = std::io::stdin();

    let mut input = entry.cmdline.clone().unwrap_or_default();
    let mut pos = input.len();
    let mut scroll = (0, 0); // (y, x)
    let mut keys = stdin.keys();

    loop {
        terminal
            .draw(|f| {
                // let input = input.as_str();
                let rect = f.size();
                let pos = pos as u16;
                let pos = if pos > scroll.1 + rect.width - 1 {
                    // text overflows rect width

                    // add one so that the cursor is always one position to the right of the last
                    // character of input
                    scroll.1 = pos - rect.width + 1;

                    rect.width - 1
                } else if scroll.1 >= pos {
                    // text underflows rect width
                    scroll.1 = pos;

                    0
                } else {
                    pos - scroll.1
                };

                let widget = Paragraph::new(input.as_str())
                    .block(Block::default().title("edit kernel params:"))
                    .scroll(scroll);
                f.render_widget(widget, f.size());
                f.set_cursor(pos, 1); // (x, y)
            })
            .ok()?;

        let Some(Ok(key)) = keys.next() else {
            break;
        };

        match key {
            Key::Esc | Key::Ctrl('[') | Key::Ctrl('c') => return None,
            Key::Backspace | Key::Ctrl('h') if pos > 0 => {
                pos -= 1;
                input = format!("{}{}", &input[..pos], &input[pos + 1..]);
            }
            Key::Ctrl('d') if pos < input.len() => {
                input = format!("{}{}", &input[..pos], &input[pos + 1..])
            }
            Key::Ctrl('u') if pos > 0 => {
                input = input[pos..].to_string();
                pos = 0;
            }
            Key::Ctrl('k') => input = input[..pos].to_string(),
            Key::Ctrl('b') | Key::Left if pos > 0 => pos -= 1,
            Key::Ctrl('f') | Key::Right if pos < input.len() => pos += 1,
            Key::Ctrl('a') | Key::Home => pos = 0,
            Key::Ctrl('e') | Key::End => pos = input.len(),
            Key::Alt('b') if pos > 0 => {
                if let Some((next_pos, _)) = input[..pos - 1]
                    .char_indices()
                    .rev()
                    .find(|(_, c)| !char::is_ascii_alphanumeric(c))
                {
                    pos -= input[..pos].len() - next_pos - 1;
                } else {
                    pos = 0;
                }
            }
            Key::Alt('f') if pos < input.len() => {
                if let Some(next_pos) = input[pos + 1..].find(|c| !char::is_ascii_alphanumeric(&c))
                {
                    pos += next_pos + 1;
                } else {
                    pos = input.len();
                }
            }
            Key::Char(c) if c != '\n' => {
                input = format!("{}{}{}", &input[..pos], c, &input[pos..]);
                pos += 1;
            }
            Key::Char('\n') | Key::Ctrl('x') => {
                let mut entry = entry;
                entry.cmdline = Some(input);
                return Some(entry);
            }
            _ => {}
        }
    }

    None
}
