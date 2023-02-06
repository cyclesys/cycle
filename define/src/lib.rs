use proc_macro::TokenStream;

use syn::parse_macro_input;

mod parse;
use parse::Definition;

#[proc_macro]
pub fn define(tokens: TokenStream) -> TokenStream {
    let definition = parse_macro_input!(tokens as Definition);
    TokenStream::new()
}
