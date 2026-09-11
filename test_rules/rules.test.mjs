/**
 * Firestore security rules.
 *
 * Run with `npm test` from this directory; the emulator needs a JDK.
 *
 * These assert the rules from the outside, as a client sees them: what the app
 * must be able to do, and what a signed-in stranger must not. Reading the rules
 * file and agreeing with it is not the same as knowing it denies anything.
 */
import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import { readFileSync } from 'node:fs';
import { doc, getDoc, setDoc, collection, getDocs } from 'firebase/firestore';

let env;

const OWNER = 'alice';
const STRANGER = 'mallory';
const PROFILE = { height: 180, weight: 75, age: 30, gender: 'MALE' };

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-void-factor',
    firestore: {
      rules: readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8'),
      host: '127.0.0.1',
      port: 8085,
    },
  });
});

after(async () => {
  await env?.cleanup();
});

const asUser = (uid) => env.authenticatedContext(uid).firestore();
const asAnon = () => env.unauthenticatedContext().firestore();

describe('users/{uid}', () => {
  it('lets a user write their own profile', async () => {
    await assertSucceeds(setDoc(doc(asUser(OWNER), 'users', OWNER), PROFILE));
  });

  it('lets a user read their own profile', async () => {
    await assertSucceeds(getDoc(doc(asUser(OWNER), 'users', OWNER)));
  });

  it("refuses to let a user read someone else's profile", async () => {
    // The reason this file exists: with no rules deployed, this read succeeds.
    await assertFails(getDoc(doc(asUser(STRANGER), 'users', OWNER)));
  });

  it("refuses to let a user overwrite someone else's profile", async () => {
    await assertFails(
      setDoc(doc(asUser(STRANGER), 'users', OWNER), { weight: 1 }),
    );
  });

  it('refuses an unauthenticated read', async () => {
    await assertFails(getDoc(doc(asAnon(), 'users', OWNER)));
  });

  it('refuses an unauthenticated write', async () => {
    await assertFails(setDoc(doc(asAnon(), 'users', OWNER), PROFILE));
  });

  it('refuses to list the users collection', async () => {
    // A list is not a read of one document: without a rule permitting it, an
    // enumeration of every uid in the project must fail.
    await assertFails(getDocs(collection(asUser(OWNER), 'users')));
  });
});

describe('everything else', () => {
  it('denies a collection the app does not own', async () => {
    await assertFails(setDoc(doc(asUser(OWNER), 'admin', 'config'), { x: 1 }));
  });

  it('denies a subcollection under the user document', async () => {
    // Account deletion removes one document and calls the remote footprint
    // gone. That is only true while nothing can create children under it.
    await assertFails(
      setDoc(doc(asUser(OWNER), 'users', OWNER, 'meals', 'm1'), { x: 1 }),
    );
  });
});
