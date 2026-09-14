import { DemoConfig } from '../Config';

@Entry
@Component
struct Index {
  @State message: string = 'FirebaseWrapper';
  @State detail: string = 'Project: ' + DemoConfig.PROJECT_ID + ' — pick a service';

  build() {
    Column() {
      Text(this.message).fontSize(28).fontWeight(FontWeight.Bold).margin(16)
      Text(this.detail).fontSize(14).margin({ left: 16, right: 16 })
      Button('Auth').margin(8).onClick(() => {
        this.message = 'Auth';
      })
      Button('Firestore').margin(8).onClick(() => {
        this.message = 'Firestore';
      })
      Button('RTDB').margin(8).onClick(() => {
        this.message = 'RTDB';
      })
      Button('RemoteConfig').margin(8).onClick(() => {
        this.message = 'RemoteConfig';
      })
      Button('FCM').margin(8).onClick(() => {
        this.message = 'FCM';
      })
      Button('AppCheck').margin(8).onClick(() => {
        this.message = 'AppCheck';
      })
    }.width('100%').height('100%')
  }
}