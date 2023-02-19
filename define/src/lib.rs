use proc_macro::TokenStream;
use syn::parse_macro_input;

mod analysis;
use analysis::Analyzer;

mod parse;
use parse::Definition;

#[proc_macro]
pub fn define(tokens: TokenStream) -> TokenStream {
    let parse_def = parse_macro_input!(tokens as Definition);
    let modules = match Analyzer::run(parse_def.0.as_slice()) {
        Ok(modules) => modules,
        Err(error) => {
            return TokenStream::from(error.to_compile_error());
        }
    };

    TokenStream::new()
}
