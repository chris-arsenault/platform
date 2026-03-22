// drift-generated
export default {
  meta: {
    type: "suggestion",
    docs: {
      description:
        "Enforce vitest as the sole test runner and .test. file naming convention across all webui apps",
    },
    messages: {
      noJestImport:
        'Do not import from "{{source}}". This project uses vitest for testing. See docs/patterns/webui-test-infrastructure.md',
      noEnzymeImport:
        'Do not import from "{{source}}". Use @testing-library/react with vitest instead. See docs/patterns/webui-test-infrastructure.md',
      useTestNotSpec:
        'Test files should use ".test." naming (e.g., Component.test.tsx), not ".spec.". Rename this file to match the project convention. See docs/patterns/webui-test-infrastructure.md',
    },
    schema: [],
  },

  create(context) {
    const filename = context.filename || context.getFilename();

    // Check file naming: .spec. should be .test.
    const specFilePattern = /\.spec\.[jt]sx?$/;
    if (specFilePattern.test(filename)) {
      context.report({
        loc: { line: 1, column: 0 },
        messageId: "useTestNotSpec",
      });
    }

    return {
      ImportDeclaration(node) {
        const source = node.source.value;

        // Ban jest imports
        if (source === "jest" || source.startsWith("@jest/")) {
          context.report({
            node,
            messageId: "noJestImport",
            data: { source },
          });
        }

        // Ban enzyme imports
        if (source === "enzyme" || source.startsWith("enzyme-")) {
          context.report({
            node,
            messageId: "noEnzymeImport",
            data: { source },
          });
        }
      },

      // Also catch require() calls
      CallExpression(node) {
        if (
          node.callee.name === "require" &&
          node.arguments.length > 0 &&
          node.arguments[0].type === "Literal"
        ) {
          const source = node.arguments[0].value;
          if (typeof source !== "string") return;

          if (source === "jest" || source.startsWith("@jest/")) {
            context.report({
              node,
              messageId: "noJestImport",
              data: { source },
            });
          }

          if (source === "enzyme" || source.startsWith("enzyme-")) {
            context.report({
              node,
              messageId: "noEnzymeImport",
              data: { source },
            });
          }
        }
      },
    };
  },
};
