// kit's ESLint config, used FROM kit at run time:
//   eslint --config <repo>/.kit/lint/eslint.config.mjs .
//
// It is not copied into a service repo. See README.md, "Where the lint configs
// run" — the mechanism is a `uses:` and a checkout, not a `cp`.
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
//
//   - `.kit/**` is ignored, and this line exists because of a measured failure
//     rather than a preference. typescript-eslint's project service has to place
//     EVERY linted file inside a tsconfig, and when this config is loaded from
//     `.kit/lint/` it is itself a linted file that belongs to none. Without the
//     ignore the run is red with
//         Parsing error: …/.kit/lint/eslint.config.mjs was not found by the
//         project service
//     which is a build failure about kit's own file, in a service that did
//     nothing wrong, on a config the service never wrote. Carried here rather
//     than left to each service, because the file is the service's problem the
//     moment it is not ours.
import js from '@eslint/js';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  {
    ignores: ['dist/**', 'build/**', 'coverage/**', '.kit/**'],
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
