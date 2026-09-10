const MAX_EXPRESSION_BYTES: usize = 256;
const MAX_TOKENS: usize = 128;
const MAX_NESTING: usize = 32;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ArithmeticError {
    Empty,
    TooLong,
    TooManyTokens,
    TooDeep,
    InvalidCharacter,
    InvalidNumber,
    UnexpectedToken,
    DivisionByZero,
    NonFinite,
    PlainNumber,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Token {
    Number(f64),
    Plus,
    Minus,
    Multiply,
    Divide,
    OpenParen,
    CloseParen,
}

fn tokenize(expression: &str) -> Result<Vec<Token>, ArithmeticError> {
    let mut tokens = Vec::new();
    let mut cursor = 0;

    while cursor < expression.len() {
        let character = expression[cursor..]
            .chars()
            .next()
            .ok_or(ArithmeticError::InvalidCharacter)?;
        if character.is_whitespace() {
            cursor += character.len_utf8();
            continue;
        }

        let token = match expression.as_bytes()[cursor] {
            b'+' => {
                cursor += 1;
                Token::Plus
            }
            b'-' => {
                cursor += 1;
                Token::Minus
            }
            b'*' => {
                cursor += 1;
                Token::Multiply
            }
            b'/' => {
                cursor += 1;
                Token::Divide
            }
            b'(' => {
                cursor += 1;
                Token::OpenParen
            }
            b')' => {
                cursor += 1;
                Token::CloseParen
            }
            b'0'..=b'9' | b'.' => {
                let start = cursor;
                let mut saw_digit = false;
                let mut saw_decimal_point = false;

                while cursor < expression.len() {
                    match expression.as_bytes()[cursor] {
                        b'0'..=b'9' => {
                            saw_digit = true;
                            cursor += 1;
                        }
                        b'.' if !saw_decimal_point => {
                            saw_decimal_point = true;
                            cursor += 1;
                        }
                        _ => break,
                    }
                }

                if !saw_digit {
                    return Err(ArithmeticError::InvalidNumber);
                }
                let value = expression[start..cursor]
                    .parse::<f64>()
                    .map_err(|_| ArithmeticError::InvalidNumber)?;
                if !value.is_finite() {
                    return Err(ArithmeticError::NonFinite);
                }
                Token::Number(value)
            }
            _ => return Err(ArithmeticError::InvalidCharacter),
        };

        tokens.push(token);
        if tokens.len() > MAX_TOKENS {
            return Err(ArithmeticError::TooManyTokens);
        }
    }

    Ok(tokens)
}

struct Parser<'a> {
    tokens: &'a [Token],
    cursor: usize,
    saw_binary_operator: bool,
}

impl<'a> Parser<'a> {
    fn new(tokens: &'a [Token]) -> Self {
        Self {
            tokens,
            cursor: 0,
            saw_binary_operator: false,
        }
    }

    fn parse(mut self) -> Result<f64, ArithmeticError> {
        let result = self.parse_sum(0)?;
        if self.cursor != self.tokens.len() {
            return Err(ArithmeticError::UnexpectedToken);
        }
        if !self.saw_binary_operator {
            return Err(ArithmeticError::PlainNumber);
        }
        finite(result)
    }

    fn parse_sum(&mut self, depth: usize) -> Result<f64, ArithmeticError> {
        let mut result = self.parse_product(depth)?;
        loop {
            let operation = match self.tokens.get(self.cursor) {
                Some(Token::Plus) => Token::Plus,
                Some(Token::Minus) => Token::Minus,
                _ => return Ok(result),
            };
            self.cursor += 1;
            self.saw_binary_operator = true;
            let right = self.parse_product(depth)?;
            result = match operation {
                Token::Plus => finite(result + right)?,
                Token::Minus => finite(result - right)?,
                _ => unreachable!(),
            };
        }
    }

    fn parse_product(&mut self, depth: usize) -> Result<f64, ArithmeticError> {
        let mut result = self.parse_unary(depth)?;
        loop {
            let operation = match self.tokens.get(self.cursor) {
                Some(Token::Multiply) => Token::Multiply,
                Some(Token::Divide) => Token::Divide,
                _ => return Ok(result),
            };
            self.cursor += 1;
            self.saw_binary_operator = true;
            let right = self.parse_unary(depth)?;
            result = match operation {
                Token::Multiply => finite(result * right)?,
                Token::Divide if right == 0.0 => return Err(ArithmeticError::DivisionByZero),
                Token::Divide => finite(result / right)?,
                _ => unreachable!(),
            };
        }
    }

    fn parse_unary(&mut self, depth: usize) -> Result<f64, ArithmeticError> {
        match self.tokens.get(self.cursor) {
            Some(Token::Plus) | Some(Token::Minus) => {
                if depth >= MAX_NESTING {
                    return Err(ArithmeticError::TooDeep);
                }
                let negative = matches!(self.tokens[self.cursor], Token::Minus);
                self.cursor += 1;
                let value = self.parse_unary(depth + 1)?;
                finite(if negative { -value } else { value })
            }
            _ => self.parse_primary(depth),
        }
    }

    fn parse_primary(&mut self, depth: usize) -> Result<f64, ArithmeticError> {
        match self.tokens.get(self.cursor).copied() {
            Some(Token::Number(value)) => {
                self.cursor += 1;
                Ok(value)
            }
            Some(Token::OpenParen) => {
                if depth >= MAX_NESTING {
                    return Err(ArithmeticError::TooDeep);
                }
                self.cursor += 1;
                let value = self.parse_sum(depth + 1)?;
                if !matches!(self.tokens.get(self.cursor), Some(Token::CloseParen)) {
                    return Err(ArithmeticError::UnexpectedToken);
                }
                self.cursor += 1;
                Ok(value)
            }
            _ => Err(ArithmeticError::UnexpectedToken),
        }
    }
}

fn finite(value: f64) -> Result<f64, ArithmeticError> {
    value
        .is_finite()
        .then_some(value)
        .ok_or(ArithmeticError::NonFinite)
}

fn format_result(value: f64) -> Result<String, ArithmeticError> {
    let value = if value == 0.0 { 0.0 } else { value };
    let compact = value.to_string();
    let result = if compact.len() <= 32 {
        compact
    } else {
        let scientific = format!("{value:.15e}");
        let (mantissa, exponent) = scientific
            .split_once('e')
            .ok_or(ArithmeticError::NonFinite)?;
        let mantissa = mantissa.trim_end_matches('0').trim_end_matches('.');
        let exponent = exponent
            .parse::<i32>()
            .map_err(|_| ArithmeticError::NonFinite)?;
        format!("{mantissa}e{exponent}")
    };
    let is_copy_safe = !result.is_empty()
        && result.len() <= 32
        && result
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'+' | b'-' | b'.' | b'e'));
    is_copy_safe
        .then_some(result)
        .ok_or(ArithmeticError::NonFinite)
}

pub fn evaluate_expression(expression: &str) -> Result<String, ArithmeticError> {
    if expression.is_empty() {
        return Err(ArithmeticError::Empty);
    }
    if expression.len() > MAX_EXPRESSION_BYTES {
        return Err(ArithmeticError::TooLong);
    }
    if expression.chars().all(char::is_whitespace) {
        return Err(ArithmeticError::Empty);
    }

    let tokens = tokenize(expression)?;
    if tokens.is_empty() {
        return Err(ArithmeticError::Empty);
    }
    format_result(Parser::new(&tokens).parse()?)
}

#[tauri::command]
pub fn calculate_arithmetic(expression: String) -> Option<String> {
    evaluate_expression(&expression).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn evaluates(expression: &str, expected: &str) {
        assert_eq!(evaluate_expression(expression), Ok(expected.to_string()));
    }

    fn rejects(expression: &str, expected: ArithmeticError) {
        assert_eq!(evaluate_expression(expression), Err(expected));
    }

    #[test]
    fn applies_precedence_parentheses_and_left_associativity() {
        evaluates("2 + 3 * 4", "14");
        evaluates("(2 + 3) * 4", "20");
        evaluates("8 / 4 / 2", "1");
        evaluates("5 - 2 - 1", "2");
        evaluates("2 * (3 + (4 - 1))", "12");
    }

    #[test]
    fn accepts_decimal_literals_and_unicode_whitespace() {
        evaluates(".5 + 1.5", "2");
        evaluates("1. + .25", "1.25");
        evaluates("\u{2003}2.5\u{00a0}*\t4\n", "10");
    }

    #[test]
    fn applies_unary_operators_in_every_operand_position() {
        evaluates("-2 * -(3 + +1)", "8");
        evaluates("1--2", "3");
        evaluates("1+-2", "-1");
        evaluates("+2 * +3", "6");
    }

    #[test]
    fn rejects_numbers_without_a_binary_operation() {
        rejects("42", ArithmeticError::PlainNumber);
        rejects("-42", ArithmeticError::PlainNumber);
        rejects("(((+42)))", ArithmeticError::PlainNumber);
    }

    #[test]
    fn rejects_empty_unknown_and_malformed_expressions() {
        rejects("", ArithmeticError::Empty);
        rejects(" \t\n", ArithmeticError::Empty);
        rejects("1 + answer", ArithmeticError::InvalidCharacter);
        rejects("1 ^ 2", ArithmeticError::InvalidCharacter);
        rejects("1e2 + 1", ArithmeticError::InvalidCharacter);
        rejects(".", ArithmeticError::InvalidNumber);
        rejects("1 +", ArithmeticError::UnexpectedToken);
        rejects("()", ArithmeticError::UnexpectedToken);
        rejects("2(3 + 4)", ArithmeticError::UnexpectedToken);
        rejects("(1 + 2", ArithmeticError::UnexpectedToken);
        rejects("1 + 2)", ArithmeticError::UnexpectedToken);
        rejects("1..2 + 3", ArithmeticError::UnexpectedToken);
    }

    #[test]
    fn rejects_division_by_positive_negative_and_computed_zero() {
        rejects("1 / 0", ArithmeticError::DivisionByZero);
        rejects("1 / -0", ArithmeticError::DivisionByZero);
        rejects("1 / (2 - 2)", ArithmeticError::DivisionByZero);
    }

    #[test]
    fn rejects_non_finite_arithmetic_values() {
        assert_eq!(finite(f64::INFINITY), Err(ArithmeticError::NonFinite));
        assert_eq!(finite(f64::NEG_INFINITY), Err(ArithmeticError::NonFinite));
        assert_eq!(finite(f64::NAN), Err(ArithmeticError::NonFinite));
        assert_eq!(
            format_result(f64::INFINITY),
            Err(ArithmeticError::NonFinite)
        );
    }

    #[test]
    fn enforces_expression_length_without_penalizing_the_boundary() {
        let accepted = format!("{}1+1", " ".repeat(MAX_EXPRESSION_BYTES - 3));
        evaluates(&accepted, "2");
        rejects(&format!("{accepted} "), ArithmeticError::TooLong);
        rejects(
            &" ".repeat(MAX_EXPRESSION_BYTES + 1),
            ArithmeticError::TooLong,
        );
    }

    #[test]
    fn enforces_token_limit_without_an_off_by_one_error() {
        let accepted = std::iter::repeat_n("1", 64).collect::<Vec<_>>().join("+");
        evaluates(&accepted, "64");

        let rejected = std::iter::repeat_n("1", 65).collect::<Vec<_>>().join("+");
        rejects(&rejected, ArithmeticError::TooManyTokens);
    }

    #[test]
    fn enforces_parenthesis_and_unary_nesting_limits() {
        let accepted_parentheses =
            format!("{}1+1{}", "(".repeat(MAX_NESTING), ")".repeat(MAX_NESTING));
        evaluates(&accepted_parentheses, "2");
        let rejected_parentheses = format!(
            "{}1+1{}",
            "(".repeat(MAX_NESTING + 1),
            ")".repeat(MAX_NESTING + 1)
        );
        rejects(&rejected_parentheses, ArithmeticError::TooDeep);

        let accepted_unary = format!("{}1+1", "+".repeat(MAX_NESTING));
        evaluates(&accepted_unary, "2");
        let rejected_unary = format!("{}1+1", "+".repeat(MAX_NESTING + 1));
        rejects(&rejected_unary, ArithmeticError::TooDeep);
    }

    #[test]
    fn returns_only_plain_copy_safe_finite_text() {
        evaluates("1 * -0", "0");
        evaluates("1 / 10000000000", "0.0000000001");

        for expression in ["1 / 3", &format!("{}+1", "9".repeat(125))] {
            let result = evaluate_expression(expression).expect("expression should evaluate");
            assert!(result.len() <= 32);
            assert!(!result.contains(char::is_whitespace));
            assert!(result
                .bytes()
                .all(|byte| byte.is_ascii_digit() || matches!(byte, b'+' | b'-' | b'.' | b'e')));
        }
    }

    #[test]
    fn command_maps_every_rejection_to_no_palette_result() {
        assert_eq!(
            calculate_arithmetic("3 * 7".to_string()),
            Some("21".to_string())
        );
        assert_eq!(calculate_arithmetic("21".to_string()), None);
        assert_eq!(calculate_arithmetic("1 / 0".to_string()), None);
    }
}
