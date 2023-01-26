use crate::boot_loader::MenuEntry;
use tui::{
    text::Spans,
    widgets::{ListItem, ListState},
};

/// Returns the list items within either the top-level entries of the menu or the entries in a
/// currently selected submenu.
pub fn list_items(items: Vec<MenuEntry<'_>>) -> Vec<ListItem> {
    items
        .iter()
        .map(|i| match i {
            MenuEntry::BootEntry(boot_entry) => {
                let lines = vec![Spans::from(boot_entry.1)];
                ListItem::new(lines)
            }
            MenuEntry::SubMenu(submenu) => {
                let lines = vec![Spans::from(format!("<->{}", submenu.0))];
                ListItem::new(lines)
            }
        })
        .collect()
}

#[derive(Debug)]
pub struct MenuList<'a> {
    pub items: Vec<MenuEntry<'a>>,
    pub display: (ListState, String, Vec<ListItem<'a>>),
    pub chosen: usize,
    pub prefix: &'a str,
}

impl<'a> MenuList<'a> {
    pub fn new(prefix: &'a str, items: Vec<MenuEntry<'a>>) -> Option<MenuList<'a>> {
        if items.is_empty() {
            None
        } else {
            let mut list = MenuList {
                display: (
                    ListState::default(),
                    prefix.to_string(),
                    list_items(items.to_vec()),
                ),
                prefix,
                chosen: 0,
                items,
            };
            list.display.0.select(Some(list.chosen));
            Some(list)
        }
    }

    pub fn next(&mut self) {
        let i = match self.display.0.selected() {
            Some(i) => {
                if i >= self.display.2.len() - 1 {
                    0
                } else {
                    i + 1
                }
            }
            None => 0,
        };

        self.display.0.select(Some(i));
    }

    pub fn previous(&mut self) {
        let i = match self.display.0.selected() {
            Some(i) => {
                if i == 0 {
                    self.display.2.len() - 1
                } else {
                    i - 1
                }
            }
            None => 0,
        };
        self.display.0.select(Some(i));
    }

    /// Selects a submenu or menuentry. If the selected entry is a boot entry, returns Some(..),
    /// else returns None.
    pub fn select(&mut self) -> Option<&str> {
        let Some(selected) = self.display.0.selected() else { return None; };
        self.chosen = selected;
        match self.items.get(selected) {
            Some(MenuEntry::SubMenu((_id, submenu_title, items))) => {
                // Set a new list to be rendered and select the first item.
                self.display.0.select(Some(0));
                let mut title = String::from(self.prefix);
                title.push_str("->");
                title.push_str(submenu_title);
                self.display.1 = title;
                self.display.2 = list_items(items.to_vec());
                None
            }
            Some(MenuEntry::BootEntry((id, _))) => Some(id),
            _ => None,
        }
    }

    /// Deselects a submenu
    pub fn exit(&mut self) {
        if let Some(MenuEntry::SubMenu((_id, _title, _entries))) = self.items.get(self.chosen) {
            self.display.0.select(Some(self.chosen));
            self.display.1 = self.prefix.to_string();
            self.display.2 = list_items(self.items.to_vec());
        }
    }
}
