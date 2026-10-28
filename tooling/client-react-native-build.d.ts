declare module 'react-native' {
  export interface TurboModule {}
  export namespace CodegenTypes {
    type EventEmitter<T> = (listener: (value: T) => void) => { remove(): void };
  }
  export const TurboModuleRegistry: { getEnforcing<T>(name: string): T };
}
