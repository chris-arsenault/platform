// drift-generated
/**
 * ESLint rule: no-js-file-extension
 *
 * Warns when a source file uses .js or .jsx extension instead of .ts or .tsx.
 * New files should always be TypeScript. Existing JS files should be migrated
 * incrementally.
 *
 * This rule enforces the "fully-typescript" canonical pattern established in
 * ADR-044. See docs/patterns/typescript-migration.md for migration guidance.
 */
export default {
  meta: {
    type: "suggestion",
    docs: {
      description:
        "Enforce .ts/.tsx file extensions instead of .js/.jsx for frontend source files",
    },
    messages: {
      useTypeScript:
        'File "{{filename}}" uses .{{ext}} extension. New files must use .{{replacement}} instead. Existing files should be migrated to TypeScript incrementally. See docs/patterns/typescript-migration.md',
    },
    schema: [],
  },

  create(context) {
    const filename = context.filename || context.getFilename();

    // Only flag .js and .jsx files
    const jsMatch = filename.match(/\.(jsx?)$/);
    if (!jsMatch) return {};

    const ext = jsMatch[1];
    const replacement = ext === "jsx" ? "tsx" : "ts";
    const shortName = filename.split("/").pop() || filename;

    return {
      Program(node) {
        context.report({
          node,
          messageId: "useTypeScript",
          data: {
            filename: shortName,
            ext,
            replacement,
          },
        });
      },
    };
  },
};
