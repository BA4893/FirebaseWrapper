import { DemoConfig } from '../Config';
import { FirebaseApp, FirebaseOptions, EmailPasswordCredential, AuthCredential } from '@openharmony/firebase';

@Entry
@Component
struct Index {
  @State message: string = 'FirebaseWrapper';
  @State detail: string = 'Project: ' + DemoConfig.PROJECT_ID + ' - pick a service';

  @State showReauth: boolean = false;
  @State reauthEmail: string = '';
  @State reauthPassword: string = '';
  @State reauthResult: string = '';

  @State showAi: boolean = false;
  @State aiFeatureName: string = 'demo-feature';
  @State aiResult: string = '';
  @State aiModel: string = '';

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
      Button('Reauthenticate').margin(8).onClick(() => {
        this.showReauth = true;
        this.reauthResult = '';
      })
      Button('AI Feature').margin(8).onClick(() => {
        this.showAi = true;
        this.aiResult = '';
        this.aiModel = '';
      })
      if (this.showAi) {
        AiPanel({
          featureName: this.aiFeatureName,
          modelName: this.aiModel,
          result: this.aiResult,
          onFeatureNameChange: (v: string) => { this.aiFeatureName = v; },
          onCancel: () => { this.showAi = false; },
          onLoadModel: () => this.loadAiFeature(),
          onRun: () => this.runAiFeature()
        })
      }

      if (this.showReauth) {
        ReauthPanel({
          email: this.reauthEmail,
          password: this.reauthPassword,
          result: this.reauthResult,
          onEmailChange: (v: string) => { this.reauthEmail = v; },
          onPasswordChange: (v: string) => { this.reauthPassword = v; },
          onCancel: () => { this.showReauth = false; },
          onSubmit: () => this.doReauth()
        })
      }
    }.width('100%').height('100%')
  }

  private async doReauth(): Promise<void> {
    this.reauthResult = 'starting...';
    try {
      const app = FirebaseApp.initialize(new FirebaseOptions(
        DemoConfig.API_KEY,
        DemoConfig.PROJECT_ID,
        DemoConfig.DATABASE_URL,
        DemoConfig.AUTH_DOMAIN,
        DemoConfig.APP_NAME
      ));
      const auth = app.auth;
      const credential: AuthCredential = new EmailPasswordCredential(this.reauthEmail, this.reauthPassword);
      await auth.reauthenticateWithCredential(credential);
      this.reauthResult = 'reauthenticated';
    } catch (err) {
      this.reauthResult = 'reauth failed: ' + err;
    }
  }

  private async loadAiFeature(): Promise<void> {
    this.aiResult = 'loading model...';
    try {
      const app = FirebaseApp.initialize(new FirebaseOptions(
        DemoConfig.API_KEY,
        DemoConfig.PROJECT_ID,
        DemoConfig.DATABASE_URL,
        DemoConfig.AUTH_DOMAIN,
        DemoConfig.APP_NAME
      ));
      const modelService = new (require('@openharmony/firebase').BackendTiedModelService as any)(
        app.http,
        'TODO_CONFIRM_MODEL_SERVICE_BASE_URL',
        async () => {
          const auth = app.auth;
          const t = await auth.idToken(false);
          return t;
        }
      );
      const modelName = await modelService.modelId(this.aiFeatureName);
      this.aiModel = modelName;
      this.aiResult = 'model: ' + modelName;
    } catch (err) {
      this.aiResult = 'model load failed: ' + err;
    }
  }

  private async runAiFeature(): Promise<void> {
    if (this.aiModel.length === 0) {
      await this.loadAiFeature();
      if (this.aiResult.startsWith('model:') === false) {
        return;
      }
    }
    this.aiResult = 'running...';
    try {
      const app = FirebaseApp.initialize(new FirebaseOptions(
        DemoConfig.API_KEY,
        DemoConfig.PROJECT_ID,
        DemoConfig.DATABASE_URL,
        DemoConfig.AUTH_DOMAIN,
        DemoConfig.APP_NAME
      ));
      const modelService = new (require('@openharmony/firebase').BackendTiedModelService as any)(
        app.http,
        'TODO_CONFIRM_MODEL_SERVICE_BASE_URL',
        async () => {
          const auth = app.auth;
          const t = await auth.idToken(false);
          return t;
        }
      );
      const feature = new (require('@openharmony/firebase').BackendTiedAiFeature as any)(
        modelService,
        'TODO_CONFIRM_AI_FEATURE_ENDPOINT',
        async () => {
          const auth = app.auth;
          const t = await auth.idToken(false);
          return t;
        }
      );
      const payload: Object = { input: 'demo' };
      const result = await feature.runString(this.aiFeatureName, payload);
      this.aiResult = result;
    } catch (err) {
      this.aiResult = 'ai run failed: ' + err;
    }
  }
}

@Component
struct AiPanel {
  featureName: string;
  modelName: string;
  result: string;
  onFeatureNameChange: (v: string) => void;
  onCancel: () => void;
  onLoadModel: () => void;
  onRun: () => void;

  build() {
    Column() {
      Text('Backend-tied AI Feature').fontSize(20).fontWeight(FontWeight.Bold).margin(16)
      TextInput({
        placeholder: 'feature name',
        text: this.featureName,
        textColor: '#000000',
        inputFilter: (input: string) => input
      }).margin(8).onChange((v) => {
        this.onFeatureNameChange(v.text);
      })
      Button('Load Model Metadata').margin(8).onClick(() => {
        this.onLoadModel();
      })
      Text(this.modelName).fontSize(14).margin(8).fontColor('#0000EE')
      Button('Run Request').margin(8).onClick(() => {
        this.onRun();
      })
      Text(this.result).fontSize(14).margin(8).fontColor('#D32F2F')
      Button('Cancel').margin(8).onClick(() => {
        this.onCancel();
      })
    }.width('100%')
  }
}

@Component
struct ReauthPanel {
  email: string;
  password: string;
  result: string;
  onEmailChange: (v: string) => void;
  onPasswordChange: (v: string) => void;
  onCancel: () => void;
  onSubmit: () => void;

  build() {
    Column() {
      Text('Reauthenticate').fontSize(20).fontWeight(FontWeight.Bold).margin(16)
      TextInput({
        placeholder: 'email',
        text: this.email,
        textColor: '#000000',
        inputFilter: (input: string) => input
      }).margin(8).onChange((v) => {
        this.onEmailChange(v.text);
      })
      TextInput({
        placeholder: 'password',
        text: this.password,
        textColor: '#000000',
        inputFilter: (input: string) => input,
        secure: true
      }).margin(8).onChange((v) => {
        this.onPasswordChange(v.text);
      })
      Button('Submit').margin(8).onClick(() => {
        this.onSubmit();
      })
      Button('Cancel').margin(8).onClick(() => {
        this.onCancel();
      })
      Text(this.result).fontSize(14).margin(8).fontColor('#D32F2F')
    }.width('100%')
  }
}

