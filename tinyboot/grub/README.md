# grub

This crate implements a lexer/parser/evaluator for the GNU grub scripting
language. Given an implementation of grub commands (menuentry, insmod, etc.),
you can use this crate to create a custom grub implementation.

This crate is alpha quality. The goal (as of right now) is to get the
configurations at [./src/testdata](./src/testdata) to work.
