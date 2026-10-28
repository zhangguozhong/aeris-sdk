import type { TurboModule, CodegenTypes } from 'react-native';
export interface Spec extends TurboModule {
    send(message: string): void;
    readonly onMessage: CodegenTypes.EventEmitter<string>;
}
declare const _default: Spec;
export default _default;
