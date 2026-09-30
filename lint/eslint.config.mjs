// Flat config for a Node service repo — copy to eslint.config.mjs, then:
//   npx eslint .
//
// STRICTNESS NOTES
//   - Flat config only (`eslint.config.mjs`), no .eslintrc: ESLint 9 reads
//     nothing else, so a repo with an .eslintrc is silently unlinted.
//   - We start from `js.configs.recommended` and then turn the rules that
//     matter for a TypeScript service on explicitly. Recommended alone does NOT
//     catch `no-floating-promises` (needs type info) or `eqeqeq` relaxations.
//   - `files` is scoped to js/mjs/cjs/ts/tsx. A config with no `files` applies to
//     every linted extension and slowly turns into a second tsconfig.
//   - No `node_modules` ignore entry on purpose: ESLint 9 ignores it by default
//     and a redundant ignore is one more thing to keep in sync.
import js from '@eslint/js';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  {
    ignores: ['dist/**', 'build/**', 'coverage/**'],
  },
  js.configs.recommended,
  ...tseslint.configs.recommendedTypeChecked,
  {
    files: ['**/*.{js,mjs,cjs,ts,tsx}'],
    languageOptions: {
      parserOptions: { projectService: true, tsconfigRootDir: import.meta.dirname },
    },
    rules: {
      eqeqeq: ['error', 'always', { null: 'ignore' }],
      'no-console': ['error', { allow: ['warn', 'error'] }],
      'prefer-const': 'error',
      'no-return-await': 'error',
    },
  },
);
