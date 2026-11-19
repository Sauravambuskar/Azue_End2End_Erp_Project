const security = require('eslint-plugin-security');

module.exports = [
  {
    files: ['src/**/*.js'],
    languageOptions: {
      ecmaVersion: 2023,
      sourceType: 'commonjs',
      globals: { process: 'readonly', console: 'readonly', fetch: 'readonly',
                 AbortSignal: 'readonly', setTimeout: 'readonly',
                 module: 'writable', require: 'readonly', __dirname: 'readonly',
                 URLSearchParams: 'readonly' },
    },
    plugins: { security },
    rules: {
      ...security.configs.recommended.rules,
      'no-eval': 'error',
      'no-implied-eval': 'error',
      'no-unused-vars': ['warn', { argsIgnorePattern: '^_' }],
    },
  },
];
