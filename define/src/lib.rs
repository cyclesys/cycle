use proc_macro::TokenStream;
use syn::parse_macro_input;

mod ir;

mod parse;
use parse::Definition;

#[proc_macro]
pub fn define(tokens: TokenStream) -> TokenStream {
    let parse_def = parse_macro_input!(tokens as Definition);
    let ir_def = match ir::gen(&parse_def) {
        Ok(ir_def) => ir_def,
        Err(error) => return TokenStream::from(error.to_compile_error()),
    };

    TokenStream::new()
}
