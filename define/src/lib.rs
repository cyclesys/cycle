use proc_macro::TokenStream;
use syn::parse_macro_input;

mod analysis;
use analysis::Analyzer;

mod parse;
use parse::Definition;

#[proc_macro]
pub fn define(tokens: TokenStream) -> TokenStream {
    let parse_def = parse_macro_input!(tokens as Definition);
    let modules = Analyzer::run(parse_def.0.as_slice());

    TokenStream::new()
}
