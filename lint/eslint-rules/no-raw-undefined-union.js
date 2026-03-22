// drift-generated
/**
 * ESLint rule: no-raw-undefined-union
 *
 * Flags two patterns in interface and type alias property signatures:
 *
 * 1. Raw `| undefined` in the type annotation — must be replaced with
 *    Optional<T>, Legacy<T>, or another named alias from
 *    packages/shared-components/src/types/optionality.ts.
 *
 * 2. The `?:` question token on a property — requires justification because
 *    in nearly all cases props are not optional: either the caller is wrong
 *    and the prop should be required, or the value can be absent and
 *    Optional<T> should be used on a required key instead.
 *
 * Rationale: forces explicit declaration of WHY a property can be undefined,
 * making LLM-added defensive optionality visible and reviewable.
 *
 * Exempt: return types, function parameters, variable declarations, type casts.
 */
export default {
  meta: {
    type: 'suggestion',
    docs: {
      description:
        'Require named optionality aliases instead of raw | undefined or ?: in property signatures',
      url: 'docs/patterns/optionality-aliases.md',
    },
    messages: {
      noRawUndefined:
        "Raw '| undefined' in property signature. In nearly all cases props are not optional — either the caller is wrong and this should be required, or there should be a discriminated union. See docs/patterns/optionality-aliases.md",
      noQuestionToken:
        "Optional property '{{name}}?:' — in nearly all cases props are not optional. Either the caller is wrong and this should be required, or there should be a discriminated union. See docs/patterns/optionality-aliases.md",
    },
    schema: [],
  },

  create(context) {
    function isInsidePropertySignature(node) {
      let current = node.parent;
      while (current) {
        if (
          current.type === 'TSPropertySignature' ||
          current.type === 'TSIndexSignature'
        ) {
          return true;
        }
        // Stop climbing at function, generic, or type boundaries that aren't property sigs
        if (
          current.type === 'TSFunctionType' ||
          current.type === 'TSMethodSignature' ||
          current.type === 'FunctionDeclaration' ||
          current.type === 'ArrowFunctionExpression' ||
          current.type === 'TSTypeParameterInstantiation' ||
          current.type === 'TSTypeAliasDeclaration'
        ) {
          return false;
        }
        current = current.parent;
      }
      return false;
    }

    function getPropertyName(node) {
      const key = node.key;
      if (!key) return '(unknown)';
      if (key.type === 'Identifier') return key.name;
      if (key.type === 'Literal') return String(key.value);
      return '(computed)';
    }

    return {
      TSUnionType(node) {
        const hasUndefined = node.types.some(
          (t) => t.type === 'TSUndefinedKeyword'
        );
        if (!hasUndefined) return;
        if (!isInsidePropertySignature(node)) return;

        context.report({ node, messageId: 'noRawUndefined' });
      },

      TSPropertySignature(node) {
        if (!node.optional) return;

        context.report({
          node,
          messageId: 'noQuestionToken',
          data: { name: getPropertyName(node) },
        });
      },
    };
  },
};
