//! forge: Moosa's tools in one place (2026-10-26, "make it work like Chris Titus's linux tools").
//! Reads ../catalog.json; usage = shell history + the timers' runs (journal) + forge's own launch log.
use crossterm::event::{self, Event, KeyCode, KeyEventKind};
use ratatui::{layout::*, style::*, text::*, widgets::*, DefaultTerminal, Frame};
use serde::Deserialize;
use std::{collections::BTreeSet, fs, io::Write, path::PathBuf, process::Command};

#[derive(Deserialize, Clone)]
struct Tool { name: String, category: String, what: String, command: String, path: String,
    #[serde(default)] timer: String, #[serde(default)] args: String,
    #[serde(skip)] runs: usize, #[serde(skip)] timer_runs: usize, #[serde(skip)] last: String }

fn home() -> PathBuf { PathBuf::from(std::env::var("HOME").unwrap_or_default()) }
fn root() -> PathBuf { home().join("Projects/smithy/forge") }
fn log_path() -> PathBuf { home().join(".local/share/forge/usage.log") }
fn expand(p: &str) -> PathBuf { if let Some(r) = p.strip_prefix("~/") { home().join(r) } else if p.starts_with('/') { PathBuf::from(p) } else { root().parent().unwrap().join(p) } }

fn load() -> Vec<Tool> {
    let mut tools: Vec<Tool> = serde_json::from_str(&fs::read_to_string(root().join("catalog.json")).unwrap_or("[]".into())).unwrap_or_default();
    let hist = fs::read_to_string(home().join(".bash_history")).unwrap_or_default();
    let log = fs::read_to_string(log_path()).unwrap_or_default();
    for t in tools.iter_mut() {
        let cmd = t.command.rsplit('/').next().unwrap_or("").to_string();
        if !cmd.is_empty() {
            t.runs = hist.lines().filter(|l| l.split_whitespace().next().map(|w| w.rsplit('/').next() == Some(cmd.as_str())).unwrap_or(false)).count();
        }
        let mine: Vec<&str> = log.lines().filter(|l| l.split('\t').nth(1) == Some(t.name.as_str())).collect();
        t.runs += mine.len();
        if let Some(l) = mine.last() { t.last = l.split('\t').next().unwrap_or("").to_string(); }
        if !t.timer.is_empty() {
            let unit = t.timer.replace(".timer", ".service");
            if let Ok(o) = Command::new("journalctl").args(["--user", "-u", &unit, "--since", "-30d", "-o", "short-iso", "--no-pager", "-q"]).output() {
                let s = String::from_utf8_lossy(&o.stdout);
                let starts: Vec<&str> = s.lines().filter(|l| l.contains("Started") || l.contains("Starting")).collect();
                t.timer_runs = starts.len();
                if t.last.is_empty() { if let Some(l) = starts.last() { t.last = l.split_whitespace().next().unwrap_or("").chars().take(16).collect(); } }
            }
        }
    }
    tools
}

struct App { tools: Vec<Tool>, cats: Vec<String>, cat: usize, sel: ListState, search: String, typing: bool, help: bool, msg: String }
impl App {
    fn shown(&self) -> Vec<&Tool> {
        let q = self.search.to_lowercase();
        self.tools.iter().filter(|t| if q.is_empty() { self.cat == 0 || t.category == self.cats[self.cat] } else { (t.name.clone() + &t.what).to_lowercase().contains(&q) }).collect()
    }
}

fn main() -> std::io::Result<()> {
    let tools = load();
    let mut cats: Vec<String> = vec!["All".into()]; cats.extend(tools.iter().map(|t| t.category.clone()).collect::<BTreeSet<_>>());
    let mut app = App { tools, cats, cat: 0, sel: ListState::default().with_selected(Some(0)), search: String::new(), typing: false, help: false, msg: String::new() };
    let mut term = ratatui::init();
    let r = run(&mut term, &mut app); ratatui::restore(); r
}

fn run(term: &mut DefaultTerminal, app: &mut App) -> std::io::Result<()> {
    loop {
        term.draw(|f| draw(f, app))?;
        if let Event::Key(k) = event::read()? {
            if k.kind != KeyEventKind::Press { continue }
            if app.typing { match k.code { KeyCode::Esc | KeyCode::Enter => app.typing = false, KeyCode::Backspace => { app.search.pop(); }
                KeyCode::Char(c) => app.search.push(c), _ => {} } app.sel.select(Some(0)); continue }
            let n = app.shown().len();
            match k.code {
                KeyCode::Char('q') | KeyCode::Esc => { if app.help { app.help = false } else { return Ok(()) } }
                KeyCode::Char('?') => app.help = !app.help,
                KeyCode::Down | KeyCode::Char('j') => app.sel.select(Some((app.sel.selected().unwrap_or(0) + 1).min(n.saturating_sub(1)))),
                KeyCode::Up | KeyCode::Char('k') => app.sel.select(Some(app.sel.selected().unwrap_or(0).saturating_sub(1))),
                KeyCode::Tab | KeyCode::Right | KeyCode::Char('l') => { app.cat = (app.cat + 1) % app.cats.len(); app.sel.select(Some(0)); app.search.clear() }
                KeyCode::BackTab | KeyCode::Left | KeyCode::Char('h') => { app.cat = (app.cat + app.cats.len() - 1) % app.cats.len(); app.sel.select(Some(0)); app.search.clear() }
                KeyCode::Char('/') => { app.typing = true; app.search.clear() }
                KeyCode::Char('r') => if let Some(t) = app.shown().get(app.sel.selected().unwrap_or(0)).map(|t| (*t).clone()) { outside(term, || {
                    let d = expand(&t.path); let readme = if d.is_dir() { ["README.md", "PLAN.md"].iter().map(|f| d.join(f)).find(|p| p.exists()) } else { None };
                    if let Some(p) = readme { let _ = Command::new(std::env::var("PAGER").unwrap_or("less".into())).arg(p).status(); } else { println!("No README for {} ({}). Enter to go back.", t.name, d.display()); wait(); } })? }
                KeyCode::Enter => if let Some(t) = app.shown().get(app.sel.selected().unwrap_or(0)).map(|t| (*t).clone()) {
                    if t.command.is_empty() { app.msg = format!("{} is a plan, not a tool yet: r opens it", t.name); continue }
                    outside(term, || {
                        let mut args = String::new();
                        if !t.args.is_empty() { print!("{} {} › ", t.name, t.args); let _ = std::io::stdout().flush(); let _ = std::io::stdin().read_line(&mut args); }
                        let line = format!("{} {}", t.command, args.trim());
                        println!("\x1b[2m$ {line}\x1b[0m");
                        let st = Command::new("bash").args(["-lc", &line]).status();
                        let _ = fs::create_dir_all(log_path().parent().unwrap());
                        let when = Command::new("date").arg("+%Y-%m-%d %H:%M").output().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default();
                        let _ = fs::OpenOptions::new().create(true).append(true).open(log_path()).and_then(|mut f| writeln!(f, "{when}\t{}\t{}", t.name, st.map(|s| s.code().unwrap_or(-1)).unwrap_or(-1)));
                        println!("\nDone. Enter to go back to forge."); wait();
                    })?;
                    let keep = app.sel.selected(); app.tools = load(); app.sel.select(keep);
                },
                _ => {}
            }
        }
    }
}
fn wait() { let mut s = String::new(); let _ = std::io::stdin().read_line(&mut s); }
fn outside(term: &mut DefaultTerminal, f: impl FnOnce()) -> std::io::Result<()> { ratatui::restore(); f(); *term = ratatui::init(); term.clear() }

const ACC: Color = Color::Rgb(0, 229, 255); const INK: Color = Color::Rgb(244, 247, 255); const MUT: Color = Color::Rgb(138, 147, 178);
fn draw(f: &mut Frame, app: &mut App) {
    let rows = Layout::vertical([Constraint::Length(3), Constraint::Min(5), Constraint::Length(1)]).split(f.area());
    let tabs = Tabs::new(app.cats.iter().map(|c| Line::from(format!(" {c} ")))).select(app.cat)
        .highlight_style(Style::new().fg(Color::Black).bg(ACC).bold()).style(Style::new().fg(MUT))
        .block(Block::bordered().border_type(BorderType::Rounded).border_style(Style::new().fg(MUT)).title(Span::styled(" forge ", Style::new().fg(ACC).bold())));
    f.render_widget(tabs, rows[0]);
    let cols = Layout::horizontal([Constraint::Percentage(42), Constraint::Percentage(58)]).split(rows[1]);
    let shown: Vec<Tool> = app.shown().into_iter().cloned().collect();
    let max = shown.iter().map(|t| t.runs + t.timer_runs).max().unwrap_or(1).max(1);
    let items: Vec<ListItem> = shown.iter().map(|t| { let u = t.runs + t.timer_runs; let bar = "▮".repeat((u * 8 + max - 1) / max);
        ListItem::new(Line::from(vec![Span::styled(format!("{:<18}", t.name), Style::new().fg(if t.command.is_empty() { MUT } else { INK })),
            Span::styled(format!("{bar:<8} "), Style::new().fg(ACC)), Span::styled(format!("{u}"), Style::new().fg(MUT))])) }).collect();
    let title = if app.typing || !app.search.is_empty() { format!(" search: {}▏", app.search) } else { format!(" {} tools ", shown.len()) };
    f.render_stateful_widget(List::new(items).highlight_style(Style::new().bg(Color::Rgb(13, 40, 48)).fg(ACC).bold()).highlight_symbol("› ")
        .block(Block::bordered().border_type(BorderType::Rounded).border_style(Style::new().fg(MUT)).title(title)), cols[0], &mut app.sel);
    let detail = if let Some(t) = shown.get(app.sel.selected().unwrap_or(0)) {
        let mut l = vec![Line::from(Span::styled(t.name.clone(), Style::new().fg(ACC).bold())), Line::raw(""), Line::from(Span::styled(t.what.clone(), Style::new().fg(INK))), Line::raw("")];
        let kv = |k: &str, v: String| Line::from(vec![Span::styled(format!("{k:<11}"), Style::new().fg(MUT)), Span::styled(v, Style::new().fg(INK))]);
        l.push(kv("category", t.category.clone()));
        l.push(kv("command", if t.command.is_empty() { "— (a plan)".into() } else { t.command.clone() }));
        if !t.args.is_empty() { l.push(kv("asks for", t.args.clone())) }
        l.push(kv("lives in", expand(&t.path).display().to_string()));
        if !t.timer.is_empty() { l.push(kv("runs by", format!("{} ({} runs in 30 days)", t.timer, t.timer_runs))) }
        l.push(kv("you ran it", format!("{} times", t.runs)));
        l.push(kv("last used", if t.last.is_empty() { "—".into() } else { t.last.clone() }));
        l.push(Line::raw("")); l.push(Line::from(Span::styled(if t.command.is_empty() { "r  open the plan" } else { "Enter  run      r  readme" }, Style::new().fg(ACC))));
        l } else { vec![Line::raw("Nothing here.")] };
    f.render_widget(Paragraph::new(detail).wrap(Wrap { trim: false }).block(Block::bordered().border_type(BorderType::Rounded).border_style(Style::new().fg(MUT)).title(" details ")), cols[1]);
    let hint = if !app.msg.is_empty() { app.msg.clone() } else { " ↑↓ choose  ←→/Tab category  Enter run  r readme  / search  ? help  q quit".into() };
    f.render_widget(Paragraph::new(Span::styled(hint, Style::new().fg(MUT))), rows[2]);
    if app.help {
        let a = Rect { x: f.area().width / 6, y: f.area().height / 5, width: f.area().width * 2 / 3, height: 12.min(f.area().height) };
        f.render_widget(Clear, a);
        f.render_widget(Paragraph::new(vec![Line::raw("forge shows every tool you have, what it does, how much you use it."), Line::raw(""),
            Line::raw("Usage = your shell history + the timer's runs (30 days) + what forge launched."), Line::raw("Add a tool: catalog.json in ~/Projects/smithy/forge (or new-tool)."), Line::raw(""),
            Line::raw("Enter  run (asks for its argument)   r  README/plan   /  search"), Line::raw("←→ Tab  categories   q  quit   ?  close this")]).wrap(Wrap { trim: false })
            .block(Block::bordered().border_type(BorderType::Rounded).border_style(Style::new().fg(ACC)).title(" help ")), a);
    }
}
