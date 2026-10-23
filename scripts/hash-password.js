// Usage: node scripts/hash-password.js "YourStrongPassword"
// Prints a bcrypt hash to paste into the seed block of scripts/users.sql.
import bcrypt from 'bcrypt';

const password = process.argv[2];

if (!password) {
  console.error('Usage: node scripts/hash-password.js "F!3r23754321"');
  process.exit(1);
}

console.log(bcrypt.hashSync(password, 10));
