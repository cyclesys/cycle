use proc_macro::TokenStream;
use syn::parse_macro_input;

mod parse;

#[proc_macro]
pub fn define(tokens: TokenStream) -> TokenStream {
    let parse_def = parse_macro_input!(tokens as parse::Definition);

    TokenStream::new()
}
